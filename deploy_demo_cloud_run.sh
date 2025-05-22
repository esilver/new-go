#!/usr/bin/env bash
# High-level helper: build & deploy rendezvous + worker for the demo (default networking).
# It builds both images with Cloud Build, deploys rendezvous, grabs its URL,
# then deploys the worker with RENDEZVOUS_SERVICE_URL set.
#
# Usage: ./deploy_demo_cloud_run.sh <PROJECT_ID> <REGION> [TAG] [NUM_WORKERS]
set -euo pipefail

# -----------------------------------------------------------------------------
# Args & sane defaults: if PROJECT_ID or REGION not supplied, fall back to the
# current gcloud configuration. This lets you simply run ./deploy_demo_cloud_run.sh
# when you already have a project/region set with `gcloud config set project ...`.
# -----------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
else
  PROJECT_ID=$1; shift
fi

if [[ -z "$PROJECT_ID" ]]; then
  echo "ERROR: PROJECT_ID not supplied and no default configured (gcloud config get-value project)." >&2
  echo "Usage: $0 <PROJECT_ID> [REGION] [TAG] [NUM_WORKERS]" >&2
  exit 1
fi

if [[ $# -lt 1 ]]; then
  REGION=$(gcloud config get-value run/region 2>/dev/null || echo "us-central1")
else
  REGION=$1; shift
fi

# Optional third positional arg is TAG (container image tag).
# Optional fourth positional arg is NUM_WORKERS (default 1).
TAG=${1:-demo}
shift || true

# If the next arg looks like an integer, treat it as NUM_WORKERS, else default 1.
if [[ ${1:-} =~ ^[0-9]+$ ]]; then
  NUM_WORKERS=$1; shift
else
  NUM_WORKERS=3
fi

echo "Will start $NUM_WORKERS worker instance(s)."

ROOT_DIR="$(cd "$(dirname "$0")"; pwd)"

# Build & deploy peerapi first (build + deploy)
"$ROOT_DIR/deploy_cloud_run.sh" peerapi "$PROJECT_ID" "$REGION" "$TAG" --min-instances=1

# Capture peerapi URL (used by both rendezvous & workers)
PEERAPI_URL=$(gcloud run services describe peerapi --project "$PROJECT_ID" --region "$REGION" --platform managed --format='value(status.url)')
if [[ -z "$PEERAPI_URL" ]]; then echo "Failed to obtain peerapi URL" >&2; exit 1; fi
echo "peerapi URL: $PEERAPI_URL"

# Build & deploy rendezvous (with PEER_DISCOVERY_URL)
"$ROOT_DIR/deploy_cloud_run.sh" rendezvous "$PROJECT_ID" "$REGION" "$TAG" --min-instances=1 --set-env-vars "PEER_DISCOVERY_URL=$PEERAPI_URL"

# -----------------------------------------------------------------------------
# Grab the service URL (useful for browser access / debugging)
# -----------------------------------------------------------------------------
# Fetch latest ready revision name to filter logs precisely
LATEST_REV=$(gcloud run services describe rendezvous \
  --project "$PROJECT_ID" --region "$REGION" --platform managed \
  --format='value(status.latestReadyRevisionName)')

RV_URL=$(gcloud run services describe rendezvous --project "$PROJECT_ID" --region "$REGION" --platform managed --format='value(status.url)')
if [[ -z "$RV_URL" ]]; then echo "Failed to obtain rendezvous URL" >&2; exit 1; fi

echo "Rendezvous URL (HTTP): $RV_URL"

# -----------------------------------------------------------------------------
# Helper: poll Cloud Run logs until we see the host-ID line or we time out.
# -----------------------------------------------------------------------------
echo "Fetching rendezvous multiaddr from Cloud Run logs of $LATEST_REV (waiting up to 60s)..." >&2
R_V_LOG_QUERY="resource.type=cloud_run_revision AND resource.labels.service_name=rendezvous AND resource.labels.revision_name=$LATEST_REV AND textPayload:(\"Host created with ID:\")"

get_peer_id_from_logs() {
  gcloud logging read "$R_V_LOG_QUERY" \
    --project="$PROJECT_ID" --limit 20 --order=DESC \
    --format="value(textPayload)" | grep -m1 "Host created with ID:" | sed -E 's/.*Host created with ID: ([A-Za-z0-9]+).*/\1/' || true
}

PEER_ID=""
# First polling loop (Cloud Logging API)
for _ in {1..2}; do  # up to 2 minutes
  PEER_ID=$(get_peer_id_from_logs)
  [[ -n "$PEER_ID" ]] && break
  sleep 5
done

# Fallback: try the managed helper (faster ingest for recent logs)
if [[ -z "$PEER_ID" ]]; then
  get_peer_id_run_logs() {
    gcloud run services logs read rendezvous --region "$REGION" --project "$PROJECT_ID" --limit 100 --format='value(textPayload)' | \
      grep -m1 "Host created with ID:" | sed -E 's/.*Host created with ID: ([A-Za-z0-9]+).*/\1/' || true
  }
  for _ in {1..12}; do # another 30s
    PEER_ID=$(get_peer_id_run_logs)
    [[ -n "$PEER_ID" ]] && break
    sleep 5
  done
fi

# Build a wss/dns multiaddr that the worker can dial over the public HTTPS endpoint
if [[ -n "$PEER_ID" ]]; then
  HOST_NO_SCHEME=${RV_URL#https://}
  HOST_NO_SCHEME=${HOST_NO_SCHEME#http://}
  RV_MULTIADDR="/dns4/${HOST_NO_SCHEME}/tcp/443/wss/p2p/${PEER_ID}"
  echo "Constructed rendezvous multiaddr: $RV_MULTIADDR"
else
  # Fallback: attempt to harvest any multiaddr in logs (may be internal and unreachable)
  RV_MULTIADDR=$(gcloud logging read "$R_V_LOG_QUERY" --project="$PROJECT_ID" --limit 20 --order=DESC --format="value(textPayload)" | \
    grep -m1 -Eo '/ip[^ ]+/p2p/[A-Za-z0-9]+' || true)
  # Ensure /ws or /wss component is present; if the multiaddr ends with '/tcp/PORT' insert '/ws' before /p2p.
  if [[ -n "$RV_MULTIADDR" && "$RV_MULTIADDR" != *"/ws/p2p"* && "$RV_MULTIADDR" != *"/wss/p2p"* ]]; then
    RV_MULTIADDR=$(echo "$RV_MULTIADDR" | sed -E 's|(tcp/[0-9]+)/p2p|\1/ws/p2p|')
  fi
  if [[ -z "$RV_MULTIADDR" ]]; then
    echo "WARNING: Could not obtain rendezvous multiaddr." >&2
  else
    echo "Detected rendezvous multiaddr: $RV_MULTIADDR (may be unreachable if internal)"
  fi
fi

# Build & deploy worker (inject env var)

ENV_VARS=("RENDEZVOUS_SERVICE_URL=$PEERAPI_URL")
if [[ -n "$RV_MULTIADDR" ]]; then ENV_VARS+=("RENDEZVOUS_MULTIADDR=$RV_MULTIADDR"); fi

# Join env vars with comma for gcloud flag
ENV_VARS_JOINED=$(IFS=, ; echo "${ENV_VARS[*]}")

# Deploy worker service with the requested baseline instances so Cloud Run spins
# them up immediately (each worker keeps an idle HTTP listener so additional
# scaling is unlikely without min-instances).
"$ROOT_DIR/deploy_cloud_run.sh" worker "$PROJECT_ID" "$REGION" "$TAG" --set-env-vars "$ENV_VARS_JOINED" --min-instances=$NUM_WORKERS --max-instances=$NUM_WORKERS --args ""

echo "\nDemo deployed!\nRendezvous HTTP URL: $RV_URL" 