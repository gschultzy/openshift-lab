#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/inventory-env.sh
source scripts/lib/inventory-env.sh

KUBECONFIG="${KUBECONFIG:-$ENV_HUB_KUBECONFIG}"
export KUBECONFIG

ACM_NAMESPACE="${ACM_NAMESPACE:-$(inventory_value acm_namespace)}"
MCH_NAME="${MCH_NAME:-$(inventory_value acm_multiclusterhub_name)}"
SUBSCRIPTION_NAME="${ACM_SUBSCRIPTION_NAME:-$(inventory_value acm_subscription_name)}"
EVENT_LINES="${ACM_DIAGNOSTICS_EVENT_LINES:-$(inventory_value acm_diagnostics_event_lines)}"
LOG_LINES="${ACM_DIAGNOSTICS_LOG_LINES:-$(inventory_value acm_diagnostics_log_lines)}"

echo
echo "================ ACM diagnostics ================"
echo "Kubeconfig: $KUBECONFIG"
echo "Namespace:  $ACM_NAMESPACE"
echo "MCH:        $MCH_NAME"
echo

echo "--- MultiClusterHub ---"
oc -n "$ACM_NAMESPACE" get mch "$MCH_NAME" -o wide 2>&1 || true
oc -n "$ACM_NAMESPACE" get mch "$MCH_NAME" -o json 2>/dev/null \
  | jq -r '.status.conditions[]? | "\(.type)=\(.status) reason=\(.reason // \"-\") message=\(.message // \"-\")"' 2>/dev/null || true

echo
echo "--- ACM Subscription and CSV ---"
oc -n "$ACM_NAMESPACE" get subscriptions.operators.coreos.com "$SUBSCRIPTION_NAME" -o wide 2>&1 || true
CSV="$(oc -n "$ACM_NAMESPACE" get subscriptions.operators.coreos.com "$SUBSCRIPTION_NAME" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
if [[ -n "$CSV" ]]; then
  oc -n "$ACM_NAMESPACE" get clusterserviceversions.operators.coreos.com "$CSV" -o wide 2>&1 || true
  oc -n "$ACM_NAMESPACE" get clusterserviceversions.operators.coreos.com "$CSV" -o json 2>/dev/null \
    | jq -r '.status.conditions[]? | "\(.phase // .type)=\(.status // \"-\") reason=\(.reason // \"-\") message=\(.message // \"-\")"' 2>/dev/null || true
fi

echo
echo "--- MultiClusterEngine status and blockers ---"
MCE_NAME="${MCE_NAME:-$(inventory_value mce_name)}"
oc get mce "$MCE_NAME" -o wide 2>&1 || true
oc get mce "$MCE_NAME" -o json 2>/dev/null \
  | jq -r '.status.conditions[]? | "\(.type)=\(.status) reason=\(.reason // "-") message=\(.message // "-")"' 2>/dev/null || true
oc get mce "$MCE_NAME" -o json 2>/dev/null \
  | jq -r '.status.components[]? | select(.status=="False" or .status=="Unknown") | "BLOCKER: \(.kind)/\(.name) status=\(.status) reason=\(.reason // "-") message=\(.message // "-")"' 2>/dev/null || true

echo
echo "--- Non-ready ACM and MCE pods ---"
oc get pods -A --no-headers 2>/dev/null \
  | awk '$1 ~ /^(open-cluster-management|multicluster-engine)/ {split($3,r,"/"); if ($4 != "Completed" && ($4 != "Running" || r[1] != r[2])) print}' \
  | head -80 || true

echo
echo "--- ACM and MCE namespace pods ---"
oc get pods -A -o wide 2>/dev/null \
  | awk 'NR==1 || $1 ~ /^(open-cluster-management|multicluster-engine)/' \
  | head -140 || true

echo
echo "--- Pending PVCs ---"
oc get pvc -A --no-headers 2>/dev/null | awk '$3 != "Bound" {print}' | head -60 || true

echo
echo "--- Unavailable or degraded cluster operators ---"
oc get clusteroperators -o json 2>/dev/null \
  | jq -r '.items[] | .metadata.name as $n | [.status.conditions[] | select((.type=="Available" and .status!="True") or (.type=="Degraded" and .status=="True")) | (.type + "=" + .status + " " + (.reason // "-") + " " + (.message // "-"))] as $bad | select(($bad | length) > 0) | ($n + ": " + ($bad | join(" | ")))' 2>/dev/null || true

echo
echo "--- Recent warning events ---"
oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -n "$EVENT_LINES" || true

echo
echo "--- MultiClusterHub operator logs ---"
OPERATOR_PODS="$(oc -n "$ACM_NAMESPACE" get pods -l name=multiclusterhub-operator -o name 2>/dev/null || true)"
if [[ -z "$OPERATOR_PODS" ]]; then
  OPERATOR_PODS="$(oc -n "$ACM_NAMESPACE" get pods -o name 2>/dev/null | grep 'multiclusterhub-operator' || true)"
fi
if [[ -n "$OPERATOR_PODS" ]]; then
  while read -r pod; do
    [[ -n "$pod" ]] || continue
    echo "===== $pod ====="
    oc -n "$ACM_NAMESPACE" logs "$pod" --all-containers --tail="$LOG_LINES" 2>&1 || true
  done <<< "$OPERATOR_PODS"
else
  echo "MultiClusterHub operator pods not found."
fi

echo "================================================="
