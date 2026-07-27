#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/inventory-env.sh
source scripts/lib/inventory-env.sh

KUBECONFIG="${KUBECONFIG:-$ENV_HUB_KUBECONFIG}"
export KUBECONFIG

ACM_NAMESPACE="${ACM_NAMESPACE:-$(inventory_value acm_namespace)}"
MCH_NAME="${MCH_NAME:-$(inventory_value acm_multiclusterhub_name)}"
SUBSCRIPTION_NAME="${ACM_SUBSCRIPTION_NAME:-$(inventory_value acm_subscription_name)}"
MCE_NAME="${MCE_NAME:-$(inventory_value mce_name)}"
TIMEOUT_SECONDS="${ACM_WAIT_TIMEOUT_SECONDS:-$(inventory_value acm_wait_timeout_seconds)}"
POLL_SECONDS="${ACM_WAIT_POLL_SECONDS:-$(inventory_value acm_wait_poll_seconds)}"

for cmd in oc jq date awk; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done
[[ -s "$KUBECONFIG" ]] || { echo "Hub kubeconfig not found: $KUBECONFIG" >&2; exit 1; }

echo
echo "Waiting for Red Hat Advanced Cluster Management to become ready"
echo "  MultiClusterHub: $ACM_NAMESPACE/$MCH_NAME"
echo "  Timeout:         ${TIMEOUT_SECONDS}s"
echo "  Poll interval:   ${POLL_SECONDS}s"
echo "Press Ctrl-C to stop waiting safely; rerunning the day-2 script is idempotent."

start_epoch="$(date +%s)"
poll=0
while true; do
  now_epoch="$(date +%s)"
  elapsed=$((now_epoch - start_epoch))
  phase="$(oc -n "$ACM_NAMESPACE" get mch "$MCH_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ -n "$phase" ]] || phase="Pending"
  csv="$(oc -n "$ACM_NAMESPACE" get subscriptions.operators.coreos.com "$SUBSCRIPTION_NAME" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
  csv_phase="unknown"
  if [[ -n "$csv" ]]; then
    csv_phase="$(oc -n "$ACM_NAMESPACE" get clusterserviceversions.operators.coreos.com "$csv" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ -n "$csv_phase" ]] || csv_phase="unknown"
  fi

  printf '\n[%s] elapsed=%02dm%02ds MCH=%s CSV=%s(%s)\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$((elapsed/60))" "$((elapsed%60))" "$phase" "${csv:-not-selected}" "$csv_phase"

  conditions="$(oc -n "$ACM_NAMESPACE" get mch "$MCH_NAME" -o json 2>/dev/null \
    | jq -r '.status.conditions[]? | select(.status=="False" or .status=="Unknown" or .type=="Complete") | "  \(.type)=\(.status) reason=\(.reason // \"-\") message=\(.message // \"-\")"' 2>/dev/null || true)"
  if [[ -n "$conditions" ]]; then
    echo "$conditions"
  fi

  mce_phase="$(oc get mce "$MCE_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  mce_available="$(oc get mce "$MCE_NAME" -o json 2>/dev/null | jq -r '.status.conditions[]? | select(.type=="Available") | .status' | tail -1)"
  printf '  MCE=%s Available=%s\n' "${mce_phase:-not-created}" "${mce_available:-unknown}"
  mce_blockers="$(oc get mce "$MCE_NAME" -o json 2>/dev/null \
    | jq -r '.status.components[]? | select(.status=="False" or .status=="Unknown") | "  BLOCKER: \(.kind)/\(.name) status=\(.status) reason=\(.reason // "-") message=\(.message // "-")"' 2>/dev/null || true)"
  if [[ -n "$mce_blockers" ]]; then
    echo "$mce_blockers"
  fi

  nonready="$(oc get pods -A --no-headers 2>/dev/null \
    | awk '$1 ~ /^(open-cluster-management|multicluster-engine)/ {split($3,r,"/"); if ($4 != "Completed" && ($4 != "Running" || r[1] != r[2])) print "  "$1"/"$2" ready="$3" status="$4" restarts="$5}' \
    | head -20 || true)"
  if [[ -n "$nonready" ]]; then
    echo "  Non-ready ACM/MCE pods:"
    echo "$nonready"
  else
    echo "  All currently created ACM/MCE pods are ready."
  fi

  if [[ "$phase" == "Running" ]]; then
    echo
    echo "ACM is Running."
    oc -n "$ACM_NAMESPACE" get mch "$MCH_NAME" -o wide
    oc get routes -A 2>/dev/null | awk 'NR==1 || $1 ~ /open-cluster-management/' | head -30 || true
    exit 0
  fi

  if (( elapsed >= TIMEOUT_SECONDS )); then
    echo >&2
    echo "ACM did not reach Running within ${TIMEOUT_SECONDS}s." >&2
    ./scripts/acm-diagnostics.sh >&2 || true
    exit 1
  fi

  # Print fuller diagnostics every five polls when progress is slow.
  poll=$((poll + 1))
  if (( poll % 5 == 0 )); then
    echo "  Recent warnings:"
    oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null \
      | tail -10 | sed 's/^/  /' || true
  fi

  sleep "$POLL_SECONDS"
done
