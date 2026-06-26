#!/usr/bin/env bash
# =============================================================================
# Delete a VTC cluster (PDF Step 5.1).
# =============================================================================
# Deletes the modelDevelopmentClusters resource. Does NOT touch Filestore or the
# GCS bucket — those are owned by Terraform (terraform destroy) or the teardown
# notebook, so we don't delete shared infra out from under the other path.
#
# Usage:
#   scripts/delete_cluster.sh --config configs/cluster_config.yaml \
#       [--cluster-id vtcgemma] [--state-in .vtc_cluster_state]
#
# If --cluster-id is omitted, it is read from the state file create_cluster.sh
# wrote.
set -euo pipefail

CONFIG=""
CLUSTER_ID=""
STATE_IN=".vtc_cluster_state"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)     CONFIG="$2"; shift 2;;
    --cluster-id) CLUSTER_ID="$2"; shift 2;;
    --state-in)   STATE_IN="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[[ -n "$CONFIG" ]] || { echo "ERROR: --config is required" >&2; exit 2; }

PROJECT_ID="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["project"]["id"])' "$CONFIG")"
REGION="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["project"]["region"])' "$CONFIG")"

if [[ -z "$CLUSTER_ID" && -f "$STATE_IN" ]]; then
  CLUSTER_ID="$(grep '^CLUSTER_ID=' "$STATE_IN" | cut -d= -f2)"
fi
[[ -n "$CLUSTER_ID" ]] || { echo "ERROR: no --cluster-id and none in $STATE_IN" >&2; exit 2; }

echo "==> deleting cluster '$CLUSTER_ID' in $PROJECT_ID/$REGION"
curl -s -X DELETE \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}/modelDevelopmentClusters/${CLUSTER_ID}"
echo
echo "==> delete requested. Track with: gcloud ai operations list --region=${REGION}"
[[ -f "$STATE_IN" ]] && rm -f "$STATE_IN" || true
