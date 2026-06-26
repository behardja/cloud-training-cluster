#!/usr/bin/env bash
# =============================================================================
# Create a VTC cluster, walking the hardware fallback chain.
# =============================================================================
# Reads configs/cluster_config.yaml, then for each profile in `fallback_chain`
# (top to bottom): render the request JSON, POST it to the v1beta1
# modelDevelopmentClusters endpoint, and poll the long-running operation. The
# FIRST profile whose create operation succeeds wins — we stop there. If a
# profile fails (stockout / quota / capacity / not allowlisted), we move on to
# the next one down the list.
#
# This is the one place the fallback lives. Both paths call it:
#   - Terraform: terraform/cluster.tf invokes it via null_resource/local-exec.
#   - Notebook:  notebooks/01-provision-cluster.ipynb shells out to it.
#
# Usage:
#   scripts/create_cluster.sh --config configs/cluster_config.yaml \
#       [--cluster-id vtcgemma] [--profiles a4b200,a3h100] [--dry-run]
#
# On success it prints, and writes to the file named by --state-out (default
# .vtc_cluster_state), two lines the teardown reads back:
#   CLUSTER_ID=<id>
#   PROFILE=<winning profile name>
#
# Requires: gcloud (authenticated), curl, python3 + PyYAML.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG=""
CLUSTER_ID=""
PROFILES=""            # optional comma-list to override/subset the chain
STATE_OUT=".vtc_cluster_state"
POLL_TIMEOUT=1800      # seconds to wait per profile's create operation
POLL_INTERVAL=20
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)      CONFIG="$2"; shift 2;;
    --cluster-id)  CLUSTER_ID="$2"; shift 2;;
    --profiles)    PROFILES="$2"; shift 2;;
    --state-out)   STATE_OUT="$2"; shift 2;;
    --poll-timeout) POLL_TIMEOUT="$2"; shift 2;;
    --dry-run)     DRY_RUN=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[[ -n "$CONFIG" ]] || { echo "ERROR: --config is required" >&2; exit 2; }

# --- read shared values out of the YAML (via the render helper's interpreter) -
read_cfg() {  # read_cfg <python-expression-on-cfg>
  python3 - "$CONFIG" "$1" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
print(eval(sys.argv[2]))
PY
}

PROJECT_ID="$(read_cfg 'cfg["project"]["id"]')"
REGION="$(read_cfg 'cfg["project"]["region"]')"

# cluster id: VTC requires <= 10 chars, unique. Default from the model name.
if [[ -z "$CLUSTER_ID" ]]; then
  MODEL="$(read_cfg 'cfg["workload"]["model"].replace("-","").replace("_","")')"
  CLUSTER_ID="$(printf '%s' "vtc${MODEL}" | cut -c1-10)"
fi
if [[ ${#CLUSTER_ID} -gt 10 ]]; then
  echo "ERROR: cluster id '$CLUSTER_ID' is >10 chars (VTC limit)" >&2
  exit 2
fi

# --- which profiles, in order ------------------------------------------------
if [[ -n "$PROFILES" ]]; then
  IFS=',' read -r -a CHAIN <<< "$PROFILES"
else
  mapfile -t CHAIN < <(python3 "$HERE/render_cluster_json.py" --config "$CONFIG" --list-profiles)
fi

echo "==> project=$PROJECT_ID region=$REGION cluster_id=$CLUSTER_ID"
echo "==> fallback chain: ${CHAIN[*]}"

API="https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/${REGION}"

# A create that is ACCEPTED then fails (LRO error / timeout) leaves a registered
# cluster object behind. Since the whole chain reuses one CLUSTER_ID, that ghost
# makes every later profile fail with ALREADY_EXISTS. Delete it before moving on.
# Only called from the paths where WE created it — never on a synchronous reject
# (which may be a pre-existing cluster we must not touch).
_delete_failed_cluster() {
  local token; token="$(gcloud auth print-access-token)"
  local dresp; dresp="$(curl -s -X DELETE -H "Authorization: Bearer ${token}" \
    "${API}/modelDevelopmentClusters/${CLUSTER_ID}")"
  local dop; dop="$(printf '%s' "$dresp" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || true)"
  if [[ -z "$dop" ]]; then
    echo "    cleanup: nothing to delete for '${CLUSTER_ID}'."
    return 0
  fi
  echo "    cleanup: deleting failed cluster '${CLUSTER_ID}' so the id frees for the next profile..."
  local w=0
  while (( w < 300 )); do
    sleep "$POLL_INTERVAL"; w=$((w + POLL_INTERVAL))
    local t2; t2="$(gcloud auth print-access-token)"
    local dstat; dstat="$(curl -s -H "Authorization: Bearer ${t2}" \
      "https://${REGION}-aiplatform.googleapis.com/v1beta1/${dop}")"
    local d; d="$(printf '%s' "$dstat" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("done", False))' 2>/dev/null || echo False)"
    [[ "$d" == "True" ]] && { echo "    cleanup: deleted."; return 0; }
  done
  echo "    cleanup: delete still pending after 300s (continuing anyway)."
  return 0
}

try_profile() {  # try_profile <profile-name> ; returns 0 on success
  local profile="$1"
  local body; body="$(mktemp /tmp/vtc_${profile}.XXXX.json)"
  python3 "$HERE/render_cluster_json.py" --config "$CONFIG" --profile "$profile" --out "$body"

  echo "----------------------------------------------------------------------"
  echo "==> trying profile '$profile'"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "    [dry-run] would POST:"; sed 's/^/      /' "$body"
    return 0
  fi

  local token; token="$(gcloud auth print-access-token)"
  local resp; resp="$(curl -s -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d @"$body" \
    "${API}/modelDevelopmentClusters?model_development_cluster_id=${CLUSTER_ID}")"

  local op; op="$(printf '%s' "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || true)"
  if [[ -z "$op" ]]; then
    echo "    create call rejected for '$profile':"; printf '%s\n' "$resp" | sed 's/^/      /'
    return 1
  fi
  echo "    operation: $op"

  # poll the LRO until done; success => break the chain, failure => next profile
  local waited=0
  while (( waited < POLL_TIMEOUT )); do
    sleep "$POLL_INTERVAL"; waited=$((waited + POLL_INTERVAL))
    local token2; token2="$(gcloud auth print-access-token)"
    local ostat; ostat="$(curl -s -H "Authorization: Bearer ${token2}" \
      "https://${REGION}-aiplatform.googleapis.com/v1beta1/${op}")"
    local done_; done_="$(printf '%s' "$ostat" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("done", False))' 2>/dev/null || echo False)"
    local err;   err="$(printf '%s' "$ostat" | python3 -c 'import sys,json; print("error" in json.load(sys.stdin))' 2>/dev/null || echo False)"
    if [[ "$done_" == "True" && "$err" == "True" ]]; then
      echo "    profile '$profile' FAILED to provision:"; printf '%s\n' "$ostat" | python3 -c 'import sys,json; print("      "+json.dumps(json.load(sys.stdin).get("error",{}),indent=2))' 2>/dev/null || true
      _delete_failed_cluster   # remove the registered-but-failed cluster so the id frees up
      return 1
    elif [[ "$done_" == "True" ]]; then
      echo "    profile '$profile' is UP."
      return 0
    fi
    echo "    ... still provisioning ($waited/${POLL_TIMEOUT}s)"
  done
  echo "    timed out waiting on '$profile' after ${POLL_TIMEOUT}s — treating as failed."
  _delete_failed_cluster   # remove the registered-but-failed cluster so the id frees up
  return 1
}

for profile in "${CHAIN[@]}"; do
  if try_profile "$profile"; then
    printf 'CLUSTER_ID=%s\nPROFILE=%s\n' "$CLUSTER_ID" "$profile" | tee "$STATE_OUT"
    echo "==> SUCCESS on '$profile'. State written to $STATE_OUT."
    exit 0
  fi
  echo "==> '$profile' did not come up; falling back to the next profile."
done

echo "ERROR: every profile in the fallback chain failed (${CHAIN[*]})." >&2
exit 1
