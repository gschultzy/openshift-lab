#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/hcp-tenants.sh
source scripts/lib/hcp-tenants.sh

ROOT_DIR="$PWD"
HUB_KUBECONFIG="${HUB_KUBECONFIG:-$ROOT_DIR/build/hub-sno/install/auth/kubeconfig}"
HCP_KUBECONFIG_OUT_DIR="${HCP_KUBECONFIG_OUT_DIR:-$ROOT_DIR/build/hub-sno/hcp-kubeconfigs}"
HCP_IMPORT_AUTO_EXPORT="${HCP_IMPORT_AUTO_EXPORT:-true}"
HCP_IMPORT_SKIP_NOT_READY="${HCP_IMPORT_SKIP_NOT_READY:-true}"
HCP_IMPORT_WAIT="${HCP_IMPORT_WAIT:-true}"
HCP_IMPORT_WAIT_RETRIES="${HCP_IMPORT_WAIT_RETRIES:-60}"
HCP_IMPORT_WAIT_DELAY="${HCP_IMPORT_WAIT_DELAY:-10}"
HCP_IMPORT_RETRY="${HCP_IMPORT_RETRY:-10}"
HCP_IMPORT_CLUSTERSET="${HCP_IMPORT_CLUSTERSET:-}"
HCP_IMPORT_CLOUD_LABEL="${HCP_IMPORT_CLOUD_LABEL:-KubeVirt}"
HCP_IMPORT_VENDOR_LABEL="${HCP_IMPORT_VENDOR_LABEL:-OpenShift}"
HCP_IMPORT_PROVIDER_LABEL="${HCP_IMPORT_PROVIDER_LABEL:-hypershift-kubevirt}"
HCP_IMPORT_CLEAN_TERMINATING_NAMESPACE="${HCP_IMPORT_CLEAN_TERMINATING_NAMESPACE:-true}"
HCP_IMPORT_FORCE_CLEANUP="${HCP_IMPORT_FORCE_CLEANUP:-false}"
HCP_IMPORT_RESET_EXISTING="${HCP_IMPORT_RESET_EXISTING:-true}"
HCP_IMPORT_NAMESPACE_WAIT_RETRIES="${HCP_IMPORT_NAMESPACE_WAIT_RETRIES:-24}"
HCP_IMPORT_NAMESPACE_WAIT_DELAY="${HCP_IMPORT_NAMESPACE_WAIT_DELAY:-5}"
HCP_IMPORT_NAMESPACE_CREATE_RETRIES="${HCP_IMPORT_NAMESPACE_CREATE_RETRIES:-36}"

require_file() {
  local path="$1"
  local label="$2"
  if [[ ! -s "$path" ]]; then
    echo "ERROR: $label is missing or empty: $path" >&2
    return 1
  fi
}

hub_oc() {
  oc --kubeconfig "$HUB_KUBECONFIG" "$@"
}

guest_oc() {
  local kubeconfig="$1"
  shift
  oc --kubeconfig "$kubeconfig" "$@"
}

is_guest_ready() {
  local kubeconfig="$1"
  guest_oc "$kubeconfig" get namespace default >/dev/null 2>&1 || return 1

  local ready_nodes="0"
  ready_nodes="$(guest_oc "$kubeconfig" get nodes --no-headers 2>/dev/null | awk '$2=="Ready" {c++} END {print c+0}')"
  [[ "$ready_nodes" -gt 0 ]] || return 1

  local cv_available=""
  cv_available="$(guest_oc "$kubeconfig" get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  [[ "$cv_available" == "True" ]] || return 1
}

print_guest_status() {
  local label="$1"
  local kubeconfig="$2"
  echo
  echo "### $label guest cluster status"
  guest_oc "$kubeconfig" get clusterversion,nodes || true
  guest_oc "$kubeconfig" get co 2>/dev/null | egrep -v ' True +False +False ' || true
}


hub_namespace_phase() {
  local ns="$1"
  hub_oc get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true
}

hub_resource_exists() {
  hub_oc get "$@" >/dev/null 2>&1
}

wait_hub_managedcluster_deleted() {
  local import_name="$1"
  local retries="${2:-$HCP_IMPORT_NAMESPACE_WAIT_RETRIES}"
  local delay="${3:-$HCP_IMPORT_NAMESPACE_WAIT_DELAY}"

  for i in $(seq 1 "$retries"); do
    if ! hub_resource_exists managedcluster "$import_name"; then
      return 0
    fi
    local deleting=""
    local finalizers=""
    deleting="$(hub_oc get managedcluster "$import_name" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)"
    finalizers="$(hub_oc get managedcluster "$import_name" -o jsonpath='{.metadata.finalizers}' 2>/dev/null || true)"
    echo "  waiting for ManagedCluster ${import_name} to disappear: attempt ${i}/${retries}, deletionTimestamp=${deleting:-none}, finalizers=${finalizers:-none}"
    sleep "$delay"
  done

  return 1
}

force_delete_hub_managedcluster() {
  local import_name="$1"

  if ! hub_resource_exists managedcluster "$import_name"; then
    return 0
  fi

  echo "Deleting stale ManagedCluster ${import_name} on hub..."
  hub_oc delete managedcluster "$import_name" --ignore-not-found --wait=false || true

  if wait_hub_managedcluster_deleted "$import_name" 3 "$HCP_IMPORT_NAMESPACE_WAIT_DELAY"; then
    return 0
  fi

  if [[ "$HCP_IMPORT_FORCE_CLEANUP" == "true" ]]; then
    echo "Force-removing stale ManagedCluster ${import_name} finalizers on hub."
    hub_oc patch managedcluster "$import_name" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    hub_oc patch managedcluster "$import_name" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
    hub_oc delete managedcluster "$import_name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi

  wait_hub_managedcluster_deleted "$import_name" "$HCP_IMPORT_NAMESPACE_WAIT_RETRIES" "$HCP_IMPORT_NAMESPACE_WAIT_DELAY"
}

finalize_hub_namespace() {
  local ns="$1"
  hub_oc get ns "$ns" >/dev/null 2>&1 || return 0
  echo "Force-finalizing hub namespace ${ns}"

  local resources
  resources="$(hub_oc api-resources --namespaced=true --verbs=list -o name 2>/dev/null | grep -v '^events' || true)"
  for r in $resources; do
    local objs
    objs="$(hub_oc -n "$ns" get "$r" -o name --ignore-not-found 2>/dev/null || true)"
    [[ -z "$objs" ]] && continue
    while IFS= read -r obj; do
      [[ -z "$obj" ]] && continue
      hub_oc -n "$ns" patch "$obj" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      hub_oc -n "$ns" delete "$obj" --ignore-not-found --force --grace-period=0 --wait=false >/dev/null 2>&1 || true
    done <<< "$objs"
  done

  local ns_json=""
  ns_json="$(hub_oc get ns "$ns" -o json 2>/dev/null || true)"
  if [[ -z "$ns_json" ]]; then
    echo "Namespace ${ns} disappeared during finalization."
    return 0
  fi

  printf '%s' "$ns_json" \
    | python3 -c 'import json,sys; raw=sys.stdin.read().strip();
import sys as _s
if not raw: _s.exit(0)
d=json.loads(raw); d.setdefault("metadata",{})["finalizers"]=[]; d.setdefault("spec",{})["finalizers"]=[]; print(json.dumps(d))' \
    | hub_oc replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
}

wait_hub_namespace_deleted() {
  local ns="$1"
  local retries="${2:-$HCP_IMPORT_NAMESPACE_WAIT_RETRIES}"
  local delay="${3:-$HCP_IMPORT_NAMESPACE_WAIT_DELAY}"
  local phase=""

  for i in $(seq 1 "$retries"); do
    phase="$(hub_namespace_phase "$ns")"
    if [[ -z "$phase" ]]; then
      return 0
    fi
    echo "  waiting for namespace ${ns} to disappear: attempt ${i}/${retries}, phase=${phase}"
    sleep "$delay"
  done

  return 1
}

wait_hub_namespace_active() {
  local ns="$1"
  local phase=""
  local deleting=""

  for i in $(seq 1 "$HCP_IMPORT_NAMESPACE_WAIT_RETRIES"); do
    phase="$(hub_namespace_phase "$ns")"
    deleting="$(hub_oc get ns "$ns" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)"
    if [[ "$phase" == "Active" && -z "$deleting" ]]; then
      return 0
    fi
    echo "  waiting for namespace ${ns} to become Active: attempt ${i}/${HCP_IMPORT_NAMESPACE_WAIT_RETRIES}, phase=${phase:-missing}, deletionTimestamp=${deleting:-none}"
    sleep "$HCP_IMPORT_NAMESPACE_WAIT_DELAY"
  done

  return 1
}


ensure_import_namespace_active_for_existing_managedcluster() {
  local import_name="$1"
  local namespace_file="$2"
  local phase=""
  local deleting=""

  # At this point the ManagedCluster already exists. RHACM/OCM owns the
  # managed-cluster namespace lifecycle, so do not delete the ManagedCluster
  # from this function. If the namespace is missing, create a plain namespace
  # first, then apply the labelled namespace manifest only after it is Active.
  for i in $(seq 1 "$HCP_IMPORT_NAMESPACE_CREATE_RETRIES"); do
    phase="$(hub_namespace_phase "$import_name")"
    deleting="$(hub_oc get ns "$import_name" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)"

    if [[ "$phase" == "Active" && -z "$deleting" ]]; then
      hub_oc apply -f "$namespace_file" >/dev/null
      echo "Namespace ${import_name} is Active."
      return 0
    fi

    if [[ "$phase" == "Terminating" || -n "$deleting" ]]; then
      echo "Namespace ${import_name} is still deleting after ManagedCluster creation: attempt ${i}/${HCP_IMPORT_NAMESPACE_CREATE_RETRIES}, phase=${phase:-missing}, deletionTimestamp=${deleting:-none}"
      if [[ "$HCP_IMPORT_FORCE_CLEANUP" == "true" ]]; then
        finalize_hub_namespace "$import_name"
      fi
      sleep "$HCP_IMPORT_NAMESPACE_WAIT_DELAY"
      continue
    fi

    if [[ -z "$phase" ]]; then
      echo "Namespace ${import_name} is missing after ManagedCluster creation; creating plain namespace: attempt ${i}/${HCP_IMPORT_NAMESPACE_CREATE_RETRIES}"
      hub_oc create ns "$import_name" >/dev/null 2>&1 || true
      sleep "$HCP_IMPORT_NAMESPACE_WAIT_DELAY"
      continue
    fi

    echo "Namespace ${import_name} is ${phase:-unknown}; waiting before import resource creation: attempt ${i}/${HCP_IMPORT_NAMESPACE_CREATE_RETRIES}"
    sleep "$HCP_IMPORT_NAMESPACE_WAIT_DELAY"
  done

  echo "ERROR: namespace ${import_name} never became Active after ManagedCluster creation." >&2
  echo "       Check with: oc --kubeconfig "$HUB_KUBECONFIG" get managedcluster ${import_name} -o yaml" >&2
  echo "       Check with: oc --kubeconfig "$HUB_KUBECONFIG" get ns ${import_name} -o yaml" >&2
  return 1
}

ensure_import_namespace_active() {
  local import_name="$1"
  local namespace_file="$2"
  local phase=""
  local deleting=""

  # RHACM managed-cluster namespaces can linger in Terminating after a previous
  # import/delete. Do not apply import resources until the old namespace object
  # is completely gone and a fresh namespace is Active. This function also
  # handles the race where `oc apply ns` returns created, but the old namespace
  # deletion immediately wins and the namespace disappears.
  for i in $(seq 1 "$HCP_IMPORT_NAMESPACE_CREATE_RETRIES"); do
    if hub_resource_exists managedcluster "$import_name"; then
      echo "ManagedCluster ${import_name} still exists while preparing namespace; deleting before namespace create: attempt ${i}/${HCP_IMPORT_NAMESPACE_CREATE_RETRIES}"
      force_delete_hub_managedcluster "$import_name"
      sleep "$HCP_IMPORT_NAMESPACE_WAIT_DELAY"
      continue
    fi

    phase="$(hub_namespace_phase "$import_name")"
    deleting="$(hub_oc get ns "$import_name" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)"

    if [[ "$phase" == "Active" && -z "$deleting" ]]; then
      echo "Namespace ${import_name} is Active."
      return 0
    fi

    if [[ "$phase" == "Terminating" || -n "$deleting" ]]; then
      echo "Namespace ${import_name} is still deleting: attempt ${i}/${HCP_IMPORT_NAMESPACE_CREATE_RETRIES}, phase=${phase:-missing}, deletionTimestamp=${deleting:-none}"
      hub_oc delete ns "$import_name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
      if [[ "$HCP_IMPORT_FORCE_CLEANUP" == "true" ]]; then
        finalize_hub_namespace "$import_name"
      fi
      sleep "$HCP_IMPORT_NAMESPACE_WAIT_DELAY"
      continue
    fi

    if [[ -z "$phase" ]]; then
      echo "Creating clean import namespace ${import_name} on hub: attempt ${i}/${HCP_IMPORT_NAMESPACE_CREATE_RETRIES}"
      hub_oc apply -f "$namespace_file"
      sleep 2
      continue
    fi

    echo "Namespace ${import_name} is ${phase:-unknown}; waiting before import resource creation: attempt ${i}/${HCP_IMPORT_NAMESPACE_CREATE_RETRIES}"
    sleep "$HCP_IMPORT_NAMESPACE_WAIT_DELAY"
  done

  echo "ERROR: namespace ${import_name} never became Active for import." >&2
  echo "       Check with: oc --kubeconfig "$HUB_KUBECONFIG" get ns ${import_name} -o yaml" >&2
  return 1
}

clean_import_target() {
  local import_name="$1"
  local phase=""

  if [[ "$HCP_IMPORT_RESET_EXISTING" != "true" ]]; then
    prepare_import_namespace "$import_name"
    return 0
  fi

  echo "Pre-cleaning RHACM import target ${import_name} on the hub..."

  # A deleting ManagedCluster can keep deleting/reaping its managed-cluster
  # namespace. Remove it first and wait for it to disappear before creating a
  # fresh import namespace, otherwise the new namespace can immediately flip
  # back to Terminating.
  hub_oc -n "$import_name" delete klusterletaddonconfig "$import_name" --ignore-not-found --wait=false 2>/dev/null || true
  hub_oc -n "$import_name" delete secret auto-import-secret --ignore-not-found --wait=false 2>/dev/null || true
  force_delete_hub_managedcluster "$import_name"

  phase="$(hub_namespace_phase "$import_name")"
  if [[ -z "$phase" ]]; then
    return 0
  fi

  echo "Existing hub namespace ${import_name} is ${phase}; deleting it before re-import."
  hub_oc delete ns "$import_name" --ignore-not-found --wait=false || true

  if wait_hub_namespace_deleted "$import_name"; then
    echo "Namespace ${import_name} is gone. Continuing import."
    return 0
  fi

  if [[ "$HCP_IMPORT_FORCE_CLEANUP" == "true" ]]; then
    echo "HCP_IMPORT_FORCE_CLEANUP=true set. Force-finalizing stale hub namespace ${import_name}."
    finalize_hub_namespace "$import_name"
    sleep 2
    if wait_hub_namespace_deleted "$import_name" 12 "$HCP_IMPORT_NAMESPACE_WAIT_DELAY"; then
      echo "Namespace ${import_name} force-cleaned. Continuing import."
      return 0
    fi
  fi

  echo "ERROR: Namespace ${import_name} is still Terminating or not deleted." >&2
  echo "       Manually inspect with: oc --kubeconfig \"$HUB_KUBECONFIG\" describe ns ${import_name}" >&2
  return 1
}

prepare_import_namespace() {
  local import_name="$1"
  local phase
  phase="$(hub_namespace_phase "$import_name")"

  if [[ "$phase" != "Terminating" ]]; then
    return 0
  fi

  echo "WARN: hub namespace ${import_name} is Terminating from a previous import/delete."
  echo "      RHACM cannot create ManagedCluster import resources until that namespace is gone."

  if [[ "$HCP_IMPORT_CLEAN_TERMINATING_NAMESPACE" != "true" ]]; then
    echo "ERROR: Set HCP_IMPORT_CLEAN_TERMINATING_NAMESPACE=true, or manually delete/finalize namespace ${import_name}." >&2
    return 1
  fi

  echo "Deleting stale ManagedCluster and namespace ${import_name} on the hub..."
  hub_oc delete managedcluster "$import_name" --ignore-not-found --wait=false || true
  hub_oc delete ns "$import_name" --ignore-not-found --wait=false || true

  if wait_hub_namespace_deleted "$import_name"; then
    echo "Namespace ${import_name} is gone. Continuing import."
    return 0
  fi

  if [[ "$HCP_IMPORT_FORCE_CLEANUP" == "true" ]]; then
    echo "HCP_IMPORT_FORCE_CLEANUP=true set. Force-finalizing stale hub namespace ${import_name}."
    finalize_hub_namespace "$import_name"
    sleep 2
    if wait_hub_namespace_deleted "$import_name" 6 "$HCP_IMPORT_NAMESPACE_WAIT_DELAY"; then
      echo "Namespace ${import_name} force-cleaned. Continuing import."
      return 0
    fi
  fi

  echo "ERROR: Namespace ${import_name} is still Terminating." >&2
  echo "       Re-run with HCP_IMPORT_FORCE_CLEANUP=true for this lab cleanup, then import again." >&2
  return 1
}

apply_import_resources() {
  local import_name="$1"
  local display_name="$2"
  local kubeconfig="$3"
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  local cluster_set_label=""
  if [[ -n "$HCP_IMPORT_CLUSTERSET" ]]; then
    cluster_set_label="    cluster.open-cluster-management.io/clusterset: ${HCP_IMPORT_CLUSTERSET}"
  fi

  cat > "$tmpdir/namespace-${import_name}.yaml" <<EOFYAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${import_name}
  labels:
    cluster.open-cluster-management.io/managedCluster: ${import_name}
EOFYAML

  cat > "$tmpdir/managedcluster-${import_name}.yaml" <<EOFYAML
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ${import_name}
  annotations:
    open-cluster-management.io/display-name: ${display_name}
  labels:
    cloud: ${HCP_IMPORT_CLOUD_LABEL}
    vendor: ${HCP_IMPORT_VENDOR_LABEL}
    hypershift.openshift.io/hosted-cluster: "true"
    hypershift.openshift.io/platform: kubevirt
    portworx-pure: "true"
${cluster_set_label}
spec:
  hubAcceptsClient: true
EOFYAML

  cat > "$tmpdir/klusterletaddonconfig-${import_name}.yaml" <<EOFYAML
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: ${import_name}
  namespace: ${import_name}
spec:
  clusterName: ${import_name}
  clusterNamespace: ${import_name}
  clusterLabels:
    cloud: ${HCP_IMPORT_CLOUD_LABEL}
    vendor: ${HCP_IMPORT_VENDOR_LABEL}
    provider: ${HCP_IMPORT_PROVIDER_LABEL}
    hypershift.openshift.io/hosted-cluster: "true"
    portworx-pure: "true"
  applicationManager:
    enabled: true
  certPolicyController:
    enabled: true
  iamPolicyController:
    enabled: true
  policyController:
    enabled: true
  searchCollector:
    enabled: true
EOFYAML

  clean_import_target "$import_name"

  # Important: create the ManagedCluster first. RHACM/OCM owns the lifecycle of
  # the namespace with the same name. Creating the managed-cluster namespace with
  # the managedCluster label before the ManagedCluster exists can cause the hub
  # controllers to immediately mark that namespace Terminating.
  echo "Applying ManagedCluster for ${import_name} on hub..."
  if ! hub_oc apply -f "$tmpdir/managedcluster-${import_name}.yaml"; then
    phase="$(hub_namespace_phase "$import_name")"
    if [[ -z "$phase" ]]; then
      echo "ManagedCluster admission did not accept a missing namespace. Creating a plain namespace and retrying..."
      hub_oc create ns "$import_name" >/dev/null 2>&1 || true
      wait_hub_namespace_active "$import_name" || true
      hub_oc apply -f "$tmpdir/managedcluster-${import_name}.yaml"
    else
      return 1
    fi
  fi

  ensure_import_namespace_active_for_existing_managedcluster "$import_name" "$tmpdir/namespace-${import_name}.yaml"

  echo "Applying KlusterletAddonConfig for ${import_name} on hub..."
  hub_oc apply -f "$tmpdir/klusterletaddonconfig-${import_name}.yaml"

  echo "Creating one-time auto-import-secret for ${import_name} from kubeconfig..."
  hub_oc -n "$import_name" delete secret auto-import-secret --ignore-not-found >/dev/null 2>&1 || true
  hub_oc -n "$import_name" create secret generic auto-import-secret \
    --from-literal=autoImportRetry="${HCP_IMPORT_RETRY}" \
    --from-file=kubeconfig="$kubeconfig"

  echo "Import resources applied for ${import_name}."
  trap - RETURN
  rm -rf "$tmpdir"
}

wait_for_import() {
  local import_name="$1"
  echo
  echo "Waiting for ${import_name} to join hub..."

  for i in $(seq 1 "$HCP_IMPORT_WAIT_RETRIES"); do
    local joined=""
    local available=""
    local import_succeeded=""
    joined="$(hub_oc get managedcluster "$import_name" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterJoined")].status}' 2>/dev/null || true)"
    available="$(hub_oc get managedcluster "$import_name" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null || true)"
    import_succeeded="$(hub_oc get managedcluster "$import_name" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterImportSucceeded")].status}' 2>/dev/null || true)"

    printf '  attempt %s/%s: Joined=%s Available=%s ImportSucceeded=%s\n' \
      "$i" "$HCP_IMPORT_WAIT_RETRIES" "${joined:-Unknown}" "${available:-Unknown}" "${import_succeeded:-Unknown}"

    if [[ "$joined" == "True" && "$available" == "True" ]]; then
      echo "${import_name} is imported and Available on the hub."
      return 0
    fi

    sleep "$HCP_IMPORT_WAIT_DELAY"
  done

  echo "WARN: ${import_name} did not become Available before timeout. Current hub status:"
  hub_oc get managedcluster "$import_name" -o wide || true
  hub_oc get managedcluster "$import_name" -o=jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}' || true
  echo
  echo "Managed-cluster agent pods on guest cluster may still be starting, or the guest cluster may not be Ready yet."
  return 1
}

import_one() {
  local label="$1"
  local import_name="$2"
  local kubeconfig="$3"

  echo
  echo "============================================================================="
  echo "Import target: $label"
  echo "Import name  : $import_name"
  echo "Kubeconfig   : $kubeconfig"
  echo "============================================================================="

  if [[ ! -s "$kubeconfig" ]]; then
    echo "Kubeconfig not found for ${label}: ${kubeconfig}"
    if [[ "$HCP_IMPORT_AUTO_EXPORT" == "true" && -x scripts/export-hcp-kubeconfigs.sh ]]; then
      echo "Trying to export HCP kubeconfigs first..."
      ./scripts/export-hcp-kubeconfigs.sh
    fi
  fi

  require_file "$kubeconfig" "$label kubeconfig"
  print_guest_status "$label" "$kubeconfig"

  if ! is_guest_ready "$kubeconfig"; then
    echo
    echo "WARN: ${label} is not fully Ready yet."
    echo "      Importing into RHACM normally needs a reachable API and Ready worker nodes so the klusterlet can run."
    if [[ "$HCP_IMPORT_SKIP_NOT_READY" == "true" ]]; then
      echo "      Skipping ${label}. Set HCP_IMPORT_SKIP_NOT_READY=false to force creation of Pending Import resources."
      return 0
    fi
    echo "      Continuing because HCP_IMPORT_SKIP_NOT_READY=false."
  fi

  apply_import_resources "$import_name" "$label" "$kubeconfig"

  if [[ "$HCP_IMPORT_WAIT" == "true" ]]; then
    wait_for_import "$import_name" || true
  fi
}

require_file "$HUB_KUBECONFIG" "hub kubeconfig"

hub_server="$(hub_oc whoami --show-server 2>/dev/null || true)"
echo "Hub kubeconfig: $HUB_KUBECONFIG"
echo "Hub API       : $hub_server"

if [[ "$hub_server" != *"api.hub-sno.poc.local"* && "${SKIP_HUB_CONTEXT_CHECK:-false}" != "true" ]]; then
  echo "ERROR: HUB_KUBECONFIG does not look like the hub-sno API. Refusing to import against the wrong cluster." >&2
  echo "Set SKIP_HUB_CONTEXT_CHECK=true only if you know this is intentional." >&2
  exit 1
fi

while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
  kubeconfig="$(hcp_tenant_kubeconfig_path "$HCP_KUBECONFIG_OUT_DIR" "$name")"
  import_one "$(hcp_tenant_site_label "$site") hosted cluster ${name}" "$mc" "$kubeconfig"
done < <(hcp_tenants)

echo
echo "Final hub managed-cluster status:"
hub_oc get managedcluster -o wide || true

echo
echo "Useful follow-up checks:"
echo "  oc --kubeconfig "$HUB_KUBECONFIG" get managedcluster"
while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
  echo "  oc --kubeconfig "$HUB_KUBECONFIG" get managedcluster ${mc} -o=jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.message}{"\n"}{end}'"
done < <(hcp_tenants)
