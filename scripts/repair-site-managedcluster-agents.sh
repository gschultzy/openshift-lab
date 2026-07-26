#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HUB_KUBECONFIG="${HUB_KUBECONFIG:-${KUBECONFIG:-$ROOT_DIR/build/hub-sno/install/auth/kubeconfig}}"

if [[ ! -f "$HUB_KUBECONFIG" ]]; then
  echo "ERROR: hub kubeconfig not found: $HUB_KUBECONFIG" >&2
  exit 1
fi

HUB_SERVER="$(oc --kubeconfig "$HUB_KUBECONFIG" whoami --show-server 2>/dev/null || true)"
echo "Using hub kubeconfig: $HUB_KUBECONFIG"
echo "Hub API server: $HUB_SERVER"

if [[ "$HUB_SERVER" != *"api.hub-sno."* && "$HUB_SERVER" != *"hub-sno"* ]]; then
  echo "ERROR: this kubeconfig does not point at hub-sno. Do not continue." >&2
  echo "Current server is: $HUB_SERVER" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required on the bastion for this repair script." >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

repair_cluster() {
  local cluster="$1"
  local spoke_kubeconfig="$2"

  echo
  echo "================================================================================"
  echo "Repairing RHACM agents for managedcluster/$cluster"
  echo "================================================================================"

  if ! oc --kubeconfig "$HUB_KUBECONFIG" get managedcluster "$cluster" >/dev/null 2>&1; then
    echo "ERROR: managedcluster/$cluster does not exist on the hub." >&2
    oc --kubeconfig "$HUB_KUBECONFIG" get managedcluster -o wide || true
    return 1
  fi

  if [[ ! -f "$spoke_kubeconfig" ]]; then
    echo "ERROR: spoke kubeconfig not found for $cluster: $spoke_kubeconfig" >&2
    echo "Re-extract or restore it before repairing this cluster." >&2
    return 1
  fi

  echo "# Hub view before repair"
  oc --kubeconfig "$HUB_KUBECONFIG" get managedcluster "$cluster" -o wide || true
  oc --kubeconfig "$HUB_KUBECONFIG" -n "$cluster" get managedclusteraddon || true

  echo
  echo "# Spoke API"
  oc --kubeconfig "$spoke_kubeconfig" whoami --show-server || true

  echo
  echo "# Existing RHACM namespaces/pods on spoke before repair"
  oc --kubeconfig "$spoke_kubeconfig" get ns open-cluster-management-agent open-cluster-management-agent-addon 2>/dev/null || true
  oc --kubeconfig "$spoke_kubeconfig" -n open-cluster-management-agent get pods -o wide 2>/dev/null || true
  oc --kubeconfig "$spoke_kubeconfig" -n open-cluster-management-agent-addon get pods -o wide 2>/dev/null || true

  echo
  echo "# Ensure hub accepts the managed cluster client"
  oc --kubeconfig "$HUB_KUBECONFIG" patch managedcluster "$cluster" --type=merge -p '{"spec":{"hubAcceptsClient":true}}' >/dev/null

  echo
  echo "# Reapply KlusterletAddonConfig on the hub"
  cat <<YAML | oc --kubeconfig "$HUB_KUBECONFIG" apply -f -
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: ${cluster}
  namespace: ${cluster}
spec:
  clusterName: ${cluster}
  clusterNamespace: ${cluster}
  clusterLabels:
    cloud: BareMetal
    vendor: OpenShift
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
YAML

  echo
  echo "# Find RHACM import secret on hub"
  local import_secret
  import_secret="$(oc --kubeconfig "$HUB_KUBECONFIG" -n "$cluster" get secret -o json 2>/dev/null | jq -r '
    .items[]?
    | select((.metadata.name | test("-import$")) or (.data["import.yaml"] != null) or (.data["crds.yaml"] != null) or (.data["klusterlet-crd.yaml"] != null))
    | .metadata.name' | head -n1 || true)"

  if [[ -n "$import_secret" ]]; then
    echo "Using import secret: $cluster/$import_secret"

    for key in klusterlet-crd.yaml crds.yaml import.yaml; do
      if oc --kubeconfig "$HUB_KUBECONFIG" -n "$cluster" get secret "$import_secret" -o json | jq -e --arg key "$key" '.data[$key] != null' >/dev/null; then
        echo "Applying $key to spoke $cluster"
        oc --kubeconfig "$HUB_KUBECONFIG" -n "$cluster" get secret "$import_secret" -o jsonpath="{.data.${key//./\\.}}" | base64 -d > "$WORKDIR/${cluster}-${key}"
        oc --kubeconfig "$spoke_kubeconfig" apply -f "$WORKDIR/${cluster}-${key}"
      fi
    done
  else
    echo "No import secret found for $cluster. This can happen for Assisted Installer-created clusters. Continuing with rollout repair."
  fi

  echo
  echo "# Restart RHACM agent deployments on spoke if present"
  oc --kubeconfig "$spoke_kubeconfig" -n open-cluster-management-agent rollout restart deploy --all 2>/dev/null || true
  oc --kubeconfig "$spoke_kubeconfig" -n open-cluster-management-agent-addon rollout restart deploy --all 2>/dev/null || true

  echo
  echo "# Wait briefly for agent pods"
  oc --kubeconfig "$spoke_kubeconfig" -n open-cluster-management-agent get pods -o wide 2>/dev/null || true
  oc --kubeconfig "$spoke_kubeconfig" -n open-cluster-management-agent-addon get pods -o wide 2>/dev/null || true

  echo
  echo "# Hub view after repair trigger"
  oc --kubeconfig "$HUB_KUBECONFIG" get managedcluster "$cluster" -o wide || true
  oc --kubeconfig "$HUB_KUBECONFIG" -n "$cluster" get managedclusteraddon || true
}

repair_cluster site-a "$ROOT_DIR/build/hub-sno/site-a/auth/kubeconfig"
repair_cluster site-b "$ROOT_DIR/build/hub-sno/site-b/auth/kubeconfig"

echo
echo "================================================================================"
echo "Watching managed cluster availability for up to 5 minutes"
echo "================================================================================"
for i in {1..30}; do
  oc --kubeconfig "$HUB_KUBECONFIG" get managedcluster -o wide
  site_a_available="$(oc --kubeconfig "$HUB_KUBECONFIG" get managedcluster site-a -o jsonpath='{range .status.conditions[?(@.type=="ManagedClusterConditionAvailable")]}{.status}{end}' 2>/dev/null || true)"
  site_b_available="$(oc --kubeconfig "$HUB_KUBECONFIG" get managedcluster site-b -o jsonpath='{range .status.conditions[?(@.type=="ManagedClusterConditionAvailable")]}{.status}{end}' 2>/dev/null || true)"
  if [[ "$site_a_available" == "True" && "$site_b_available" == "True" ]]; then
    echo "Site-A and Site-B are Available=True."
    exit 0
  fi
  sleep 10
done

echo
echo "Repair was applied, but one or both clusters are still not Available=True."
echo "Run these for details:"
echo "  oc -n site-a describe managedclusteraddon work-manager"
echo "  oc -n site-b describe managedclusteraddon work-manager"
echo "  oc --kubeconfig build/hub-sno/site-a/auth/kubeconfig -n open-cluster-management-agent get pods -o wide"
echo "  oc --kubeconfig build/hub-sno/site-b/auth/kubeconfig -n open-cluster-management-agent get pods -o wide"
exit 2
