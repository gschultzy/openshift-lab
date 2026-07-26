#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

HUB_KUBECONFIG="${HUB_KUBECONFIG:-$PWD/build/lab-sno/install/auth/kubeconfig}"
SITEA_KUBECONFIG="${SITEA_KUBECONFIG:-$PWD/build/lab-sno/site-a/auth/kubeconfig}"
HCP_NAME="${SITE_A_HCP_NAME:-site-a-hcp-t1-px}"
HCP_NS="${SITE_A_HCP_NAMESPACE:-clusters}"
IMPORT_NAME="${SITE_A_HCP_IMPORT_NAME:-${HCP_NAME}}"
HCP_HOSTING_NS="clusters-${HCP_NAME}"
KLUSTERLET_NS="klusterlet-${IMPORT_NAME}"
CLEAN_OLD_SPOKE_MCE_NAMESPACES="${CLEAN_OLD_SPOKE_MCE_NAMESPACES:-true}"

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Missing required kubeconfig: $1" >&2
    exit 1
  fi
}

server_for() {
  oc --kubeconfig "$1" whoami --show-server 2>/dev/null || true
}

require_file "$HUB_KUBECONFIG"
require_file "$SITEA_KUBECONFIG"

HUB_SERVER="$(server_for "$HUB_KUBECONFIG")"
SITEA_SERVER="$(server_for "$SITEA_KUBECONFIG")"

echo "Hub API:    $HUB_SERVER"
echo "Site-A API: $SITEA_SERVER"
echo "HCP:        $HCP_NS/$HCP_NAME"
echo

if [[ "$HUB_SERVER" != *"lab-sno"* ]]; then
  echo "Refusing to continue: HUB_KUBECONFIG does not look like lab-sno." >&2
  exit 1
fi

if [[ "$SITEA_SERVER" != *"site-a"* ]]; then
  echo "Refusing to continue: SITEA_KUBECONFIG does not look like site-a." >&2
  exit 1
fi

patch_finalizers() {
  local kubeconfig=$1
  local obj=$2
  oc --kubeconfig "$kubeconfig" patch "$obj" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
}

patch_namespaced_finalizers() {
  local kubeconfig=$1
  local ns=$2
  local obj=$3
  oc --kubeconfig "$kubeconfig" -n "$ns" patch "$obj" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
}

finalize_namespace() {
  local kubeconfig=$1
  local ns=$2
  if ! oc --kubeconfig "$kubeconfig" get ns "$ns" >/dev/null 2>&1; then
    return 0
  fi

  echo "Force-finalizing namespace: $ns"
  oc --kubeconfig "$kubeconfig" get ns "$ns" -o json \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); d.setdefault("spec",{})["finalizers"]=[]; d.setdefault("metadata",{})["finalizers"]=[]; print(json.dumps(d))' \
    | oc --kubeconfig "$kubeconfig" replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
}

clear_namespace_contents() {
  local kubeconfig=$1
  local ns=$2
  if ! oc --kubeconfig "$kubeconfig" get ns "$ns" >/dev/null 2>&1; then
    return 0
  fi

  echo "Clearing namespaced finalizers/resources in: $ns"
  local resources
  resources=$(oc --kubeconfig "$kubeconfig" api-resources --namespaced=true --verbs=list -o name 2>/dev/null | grep -v '^events' || true)
  for r in $resources; do
    local objs
    objs=$(oc --kubeconfig "$kubeconfig" -n "$ns" get "$r" -o name --ignore-not-found 2>/dev/null || true)
    [[ -z "$objs" ]] && continue
    while IFS= read -r obj; do
      [[ -z "$obj" ]] && continue
      patch_namespaced_finalizers "$kubeconfig" "$ns" "$obj"
      oc --kubeconfig "$kubeconfig" -n "$ns" delete "$obj" --ignore-not-found --grace-period=0 --force --wait=false >/dev/null 2>&1 || true
    done <<< "$objs"
  done
}

echo "# 1) Unimport/delete RHACM managed cluster for old HCP guest"
oc --kubeconfig "$HUB_KUBECONFIG" delete managedcluster "$IMPORT_NAME" --ignore-not-found --wait=false || true
oc --kubeconfig "$HUB_KUBECONFIG" delete klusterletaddonconfig "$IMPORT_NAME" -n "$IMPORT_NAME" --ignore-not-found --wait=false || true
oc --kubeconfig "$HUB_KUBECONFIG" delete ns "$IMPORT_NAME" --ignore-not-found --wait=false || true
patch_finalizers "$HUB_KUBECONFIG" "managedcluster/$IMPORT_NAME"

# Remove discovered cluster record for this HCP on hub.
DISCOVERED=$(oc --kubeconfig "$HUB_KUBECONFIG" -n site-a get discoveredcluster \
  -l hypershift.open-cluster-management.io/hc-name="$HCP_NAME" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
for dc in $DISCOVERED; do
  echo "Deleting DiscoveredCluster site-a/$dc"
  oc --kubeconfig "$HUB_KUBECONFIG" -n site-a patch discoveredcluster "$dc" --type=merge -p '{"spec":{"importAsManagedCluster":false}}' >/dev/null 2>&1 || true
  oc --kubeconfig "$HUB_KUBECONFIG" -n site-a patch discoveredcluster "$dc" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  oc --kubeconfig "$HUB_KUBECONFIG" -n site-a delete discoveredcluster "$dc" --ignore-not-found --grace-period=0 --force --wait=false || true
done

echo

echo "# 2) Delete HostedCluster/NodePool and remove finalizers if stuck"
oc --kubeconfig "$SITEA_KUBECONFIG" -n "$HCP_NS" delete nodepool "$HCP_NAME" --ignore-not-found --wait=false || true
oc --kubeconfig "$SITEA_KUBECONFIG" -n "$HCP_NS" delete hostedcluster "$HCP_NAME" --ignore-not-found --wait=false || true
patch_namespaced_finalizers "$SITEA_KUBECONFIG" "$HCP_NS" "nodepool/$HCP_NAME"
patch_namespaced_finalizers "$SITEA_KUBECONFIG" "$HCP_NS" "hostedcluster/$HCP_NAME"
oc --kubeconfig "$SITEA_KUBECONFIG" -n "$HCP_NS" delete nodepool "$HCP_NAME" --ignore-not-found --grace-period=0 --force --wait=false || true
oc --kubeconfig "$SITEA_KUBECONFIG" -n "$HCP_NS" delete hostedcluster "$HCP_NAME" --ignore-not-found --grace-period=0 --force --wait=false || true

echo

echo "# 3) Delete/clear old HCP hosting namespace and klusterlet namespace"
oc --kubeconfig "$SITEA_KUBECONFIG" delete ns "$HCP_HOSTING_NS" "$KLUSTERLET_NS" --ignore-not-found --wait=false || true
clear_namespace_contents "$SITEA_KUBECONFIG" "$HCP_HOSTING_NS"
clear_namespace_contents "$SITEA_KUBECONFIG" "$KLUSTERLET_NS"
finalize_namespace "$SITEA_KUBECONFIG" "$HCP_HOSTING_NS"
finalize_namespace "$SITEA_KUBECONFIG" "$KLUSTERLET_NS"

if [[ "$CLEAN_OLD_SPOKE_MCE_NAMESPACES" == "true" ]]; then
  echo
  echo "# 4) Clean old local-MCE namespaces on Site-A only if already Terminating"
  # These namespaces should not exist on Site-A in this hub-managed hosting model.
  # Only force-finalize them when Kubernetes already marks them Terminating.
  for ns in multicluster-engine open-cluster-management-hub; do
    phase=$(oc --kubeconfig "$SITEA_KUBECONFIG" get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$phase" == "Terminating" ]]; then
      echo "Namespace $ns is Terminating; clearing it on Site-A."
      clear_namespace_contents "$SITEA_KUBECONFIG" "$ns"
      finalize_namespace "$SITEA_KUBECONFIG" "$ns"
    else
      echo "Namespace $ns phase is '${phase:-not-present}'; leaving it alone."
    fi
  done
fi

echo

echo "# 5) Remove stale OCM APIService entries from Site-A if present"
oc --kubeconfig "$SITEA_KUBECONFIG" delete apiservice \
  v1.clusterview.open-cluster-management.io \
  v1alpha1.clusterview.open-cluster-management.io \
  v1beta1.proxy.open-cluster-management.io \
  --ignore-not-found || true

echo

echo "# 6) Current status"
oc --kubeconfig "$SITEA_KUBECONFIG" -n "$HCP_NS" get hostedcluster,nodepool "$HCP_NAME" --ignore-not-found || true
oc --kubeconfig "$SITEA_KUBECONFIG" get ns | egrep "^(${HCP_HOSTING_NS}|${KLUSTERLET_NS}|multicluster-engine|open-cluster-management-hub)\\b" || true
oc --kubeconfig "$HUB_KUBECONFIG" get managedcluster | egrep "$IMPORT_NAME|site-b-hcp-t1-px|site-a-hcp-t1-px|site-a\b|site-b\b|local-cluster" || true

echo

echo "Done. If clusters-${HCP_NAME} is gone, rerun:"
echo "  ./scripts/hcp-create.sh"
