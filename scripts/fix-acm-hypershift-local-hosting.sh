#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/inventory-env.sh
source scripts/lib/inventory-env.sh

KUBECONFIG="${KUBECONFIG:-$ENV_HUB_KUBECONFIG}"
export KUBECONFIG

MCE_NAME="${MCE_NAME:-$(inventory_value mce_name)}"
MCH_NAMESPACE="${ACM_NAMESPACE:-$(inventory_value acm_namespace)}"
MCH_NAME="${MCH_NAME:-$(inventory_value acm_multiclusterhub_name)}"
LOCAL_CLUSTER_NAME="${MCE_LOCAL_CLUSTER_NAME:-$(inventory_value mce_local_cluster_name)}"
HYPERSHIFT_ADDON_NAME="${MCE_HYPERSHIFT_ADDON_NAME:-$(inventory_value mce_hypershift_addon_name)}"
HYPERSHIFT_ADDON_WORK_NAMESPACE="${MCE_HYPERSHIFT_ADDON_WORK_NAMESPACE:-$(inventory_value mce_hypershift_addon_work_namespace)}"
HYPERSHIFT_ENABLED="${MCE_HYPERSHIFT_ENABLED:-$(inventory_value mce_hypershift_enabled)}"
LOCAL_HOSTING_ENABLED="${MCE_HYPERSHIFT_LOCAL_HOSTING_ENABLED:-$(inventory_value mce_hypershift_local_hosting_enabled)}"
REMOVE_STALE_ADDON="${MCE_REMOVE_STALE_LOCAL_HYPERSHIFT_ADDON:-$(inventory_value mce_remove_stale_local_hypershift_addon)}"
CLEANUP_GRACE="${MCE_LOCAL_ADDON_CLEANUP_GRACE_SECONDS:-$(inventory_value mce_local_addon_cleanup_grace_seconds)}"
ADDON_DELETE_TIMEOUT="${MCE_LOCAL_ADDON_DELETE_TIMEOUT_SECONDS:-$(inventory_value mce_local_addon_delete_timeout_seconds)}"
TIMEOUT_SECONDS="${MCE_REPAIR_TIMEOUT_SECONDS:-$(inventory_value mce_repair_timeout_seconds)}"
POLL_SECONDS="${MCE_REPAIR_POLL_SECONDS:-$(inventory_value mce_repair_poll_seconds)}"

truthy() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

json_bool() {
  if truthy "$1"; then printf 'true'; else printf 'false'; fi
}

for cmd in oc jq date sleep; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done
[[ -s "$KUBECONFIG" ]] || { echo "Hub kubeconfig not found: $KUBECONFIG" >&2; exit 1; }

if ! oc get clusterversion version >/dev/null 2>&1; then
  echo "Cannot reach the SNO hub with kubeconfig: $KUBECONFIG" >&2
  exit 1
fi

if ! oc get crd multiclusterengines.multicluster.openshift.io >/dev/null 2>&1; then
  echo "The MultiClusterEngine CRD is not installed yet. Install ACM first." >&2
  exit 1
fi

if ! oc get mce "$MCE_NAME" >/dev/null 2>&1; then
  echo "Waiting for MultiClusterEngine/$MCE_NAME to be created..."
  for _ in $(seq 1 120); do
    oc get mce "$MCE_NAME" >/dev/null 2>&1 && break
    sleep 5
  done
fi
oc get mce "$MCE_NAME" >/dev/null 2>&1 || {
  echo "MultiClusterEngine/$MCE_NAME was not created." >&2
  exit 1
}

if ! truthy "$LOCAL_HOSTING_ENABLED" && oc get crd hostedclusters.hypershift.openshift.io >/dev/null 2>&1; then
  local_hcs="$(oc get hostedcluster -A --no-headers 2>/dev/null || true)"
  if [[ -n "$local_hcs" ]]; then
    echo "Refusing to disable local HCP hosting because HostedCluster objects exist on the SNO hub:" >&2
    echo "$local_hcs" >&2
    echo "Move or delete those hosted clusters first. HostedClusters on Site-A/Site-B are unaffected because they live on those hosting clusters." >&2
    exit 1
  fi
fi

if ! truthy "$LOCAL_HOSTING_ENABLED"; then
  echo "Ensuring HyperShift add-on work namespace exists: $HYPERSHIFT_ADDON_WORK_NAMESPACE"
  oc create namespace "$HYPERSHIFT_ADDON_WORK_NAMESPACE" --dry-run=client -o yaml | oc apply -f - >/dev/null
fi

current_components="$(oc get mce "$MCE_NAME" -o json | jq '.spec.overrides.components // []')"
updated_components="$(
  jq \
    --argjson hypershift "$(json_bool "$HYPERSHIFT_ENABLED")" \
    --argjson localHosting "$(json_bool "$LOCAL_HOSTING_ENABLED")" \
    'map(select(.name != "hypershift" and .name != "hypershift-local-hosting"))
     + [{"name":"hypershift","enabled":$hypershift},
        {"name":"hypershift-local-hosting","enabled":$localHosting}]' \
    <<<"$current_components"
)"
patch_payload="$(jq -nc --argjson components "$updated_components" '{spec:{overrides:{components:$components}}}')"

echo
echo "Configuring MCE Hosted Control Planes topology"
echo "  MCE:                       $MCE_NAME"
echo "  Global HCP feature:        $HYPERSHIFT_ENABLED"
echo "  SNO local HCP hosting:     $LOCAL_HOSTING_ENABLED"
echo "  Dedicated HCP hosts:       $ENV_SITE_A_CLUSTER_NAME, $ENV_SITE_B_CLUSTER_NAME"

oc patch mce "$MCE_NAME" --type=merge -p "$patch_payload"

# Trigger fresh status reconciliation without changing functional configuration.
reconcile_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
oc annotate mce "$MCE_NAME" openshift-lab/reconcile-at="$reconcile_at" --overwrite >/dev/null
oc -n "$MCH_NAMESPACE" annotate mch "$MCH_NAME" openshift-lab/reconcile-at="$reconcile_at" --overwrite >/dev/null 2>&1 || true

if ! truthy "$LOCAL_HOSTING_ENABLED"; then
  echo "Waiting up to ${CLEANUP_GRACE}s for MCE to remove the local-cluster HyperShift add-on..."
  grace_start="$(date +%s)"
  while oc -n "$LOCAL_CLUSTER_NAME" get managedclusteraddon "$HYPERSHIFT_ADDON_NAME" >/dev/null 2>&1; do
    now="$(date +%s)"
    (( now - grace_start >= CLEANUP_GRACE )) && break
    sleep "$POLL_SECONDS"
  done

  if oc -n "$LOCAL_CLUSTER_NAME" get managedclusteraddon "$HYPERSHIFT_ADDON_NAME" >/dev/null 2>&1; then
    addon_reason="$(oc -n "$LOCAL_CLUSTER_NAME" get managedclusteraddon "$HYPERSHIFT_ADDON_NAME" -o json 2>/dev/null \
      | jq -r '.status.conditions[]? | select(.type=="Available") | .reason' | tail -1)"
    if truthy "$REMOVE_STALE_ADDON"; then
      echo "Removing stale $LOCAL_CLUSTER_NAME/$HYPERSHIFT_ADDON_NAME add-on (reason=${addon_reason:-unknown})."
      oc -n "$LOCAL_CLUSTER_NAME" delete managedclusteraddon "$HYPERSHIFT_ADDON_NAME" --ignore-not-found --wait=false

      retry_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      for work in addon-${HYPERSHIFT_ADDON_NAME}-deploy-0 addon-${HYPERSHIFT_ADDON_NAME}-pre-delete; do
        if oc -n "$LOCAL_CLUSTER_NAME" get manifestwork "$work" >/dev/null 2>&1; then
          oc -n "$LOCAL_CLUSTER_NAME" annotate manifestwork "$work" \
            openshift-lab/retry-at="$retry_at" --overwrite >/dev/null
        fi
      done

      echo "Waiting up to ${ADDON_DELETE_TIMEOUT}s for local add-on cleanup to finish..."
      delete_start="$(date +%s)"
      while oc -n "$LOCAL_CLUSTER_NAME" get managedclusteraddon "$HYPERSHIFT_ADDON_NAME" >/dev/null 2>&1; do
        now="$(date +%s)"
        if (( now - delete_start >= ADDON_DELETE_TIMEOUT )); then
          echo "Local HyperShift add-on cleanup did not finish within ${ADDON_DELETE_TIMEOUT}s." >&2
          oc -n "$LOCAL_CLUSTER_NAME" get managedclusteraddon "$HYPERSHIFT_ADDON_NAME" -o yaml >&2 || true
          oc -n "$LOCAL_CLUSTER_NAME" get manifestwork \
            addon-${HYPERSHIFT_ADDON_NAME}-deploy-0 addon-${HYPERSHIFT_ADDON_NAME}-pre-delete \
            -o wide >&2 2>/dev/null || true
          exit 1
        fi
        sleep "$POLL_SECONDS"
      done
      echo "The local-cluster HyperShift add-on cleanup completed."
    else
      echo "The local add-on still exists; automatic stale-add-on removal is disabled." >&2
    fi
  fi
fi

echo
echo "Waiting for MCE Available=True and MultiClusterHub Running..."
start_epoch="$(date +%s)"
while true; do
  now_epoch="$(date +%s)"
  elapsed=$((now_epoch - start_epoch))

  mce_phase="$(oc get mce "$MCE_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  mce_available="$(oc get mce "$MCE_NAME" -o json 2>/dev/null | jq -r '.status.conditions[]? | select(.type=="Available") | .status' | tail -1)"
  mch_phase="$(oc -n "$MCH_NAMESPACE" get mch "$MCH_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  local_addon="absent"
  if oc -n "$LOCAL_CLUSTER_NAME" get managedclusteraddon "$HYPERSHIFT_ADDON_NAME" >/dev/null 2>&1; then
    local_addon="present"
  fi

  printf '[%s] elapsed=%02dm%02ds MCE=%s Available=%s MCH=%s local-addon=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$((elapsed/60))" "$((elapsed%60))" \
    "${mce_phase:-unknown}" "${mce_available:-unknown}" "${mch_phase:-unknown}" "$local_addon"

  if [[ "$mce_available" == "True" && "$mch_phase" == "Running" ]]; then
    break
  fi

  if (( elapsed >= TIMEOUT_SECONDS )); then
    echo "MCE/ACM did not recover within ${TIMEOUT_SECONDS}s." >&2
    echo >&2
    oc get mce "$MCE_NAME" -o json 2>/dev/null \
      | jq -r '.status.components[]? | select(.status=="False" or .status=="Unknown") | "MCE component: \(.kind)/\(.name) status=\(.status) reason=\(.reason) message=\(.message)"' >&2 || true
    oc -n "$MCH_NAMESPACE" get mch "$MCH_NAME" -o json 2>/dev/null \
      | jq -r '.status.conditions[]? | "MCH: \(.type)=\(.status) reason=\(.reason) message=\(.message)"' >&2 || true
    exit 1
  fi
  sleep "$POLL_SECONDS"
done

echo
echo "ACM/MCE repair completed successfully."
oc get mce "$MCE_NAME" -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,VERSION:.status.currentVersion
oc -n "$MCH_NAMESPACE" get mch "$MCH_NAME" -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,VERSION:.status.currentVersion

echo
echo "HyperShift add-ons on hosting clusters (shown only when the clusters exist):"
for cluster in "$ENV_SITE_A_CLUSTER_NAME" "$ENV_SITE_B_CLUSTER_NAME"; do
  if oc get managedcluster "$cluster" >/dev/null 2>&1; then
    oc -n "$cluster" get managedclusteraddon "$HYPERSHIFT_ADDON_NAME" -o wide 2>/dev/null \
      || echo "$cluster: hypershift-addon will be created by the HCP hosting integration step."
  fi
done
