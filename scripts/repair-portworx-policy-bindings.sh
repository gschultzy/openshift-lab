#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

HUB_KUBECONFIG="${HUB_KUBECONFIG:-$PWD/build/hub-sno/install/auth/kubeconfig}"
export KUBECONFIG="$HUB_KUBECONFIG"

if [[ ! -f "$HUB_KUBECONFIG" ]]; then
  echo "Hub kubeconfig not found: $HUB_KUBECONFIG" >&2
  exit 1
fi

./scripts/ensure-hub-kubeconfig.sh >/dev/null 2>&1 || true

api_server="$(oc --kubeconfig "$HUB_KUBECONFIG" whoami --show-server)"
if [[ "$api_server" != *"api.hub-sno.poc.local"* ]]; then
  echo "Refusing to repair Portworx policy bindings because this does not look like hub-sno." >&2
  echo "Current API server: $api_server" >&2
  echo "Expected: api.hub-sno.poc.local" >&2
  exit 1
fi

ns="portworx-pure-policies"
placement="portworx-pure-placement"

oc --kubeconfig "$HUB_KUBECONFIG" get ns "$ns" >/dev/null
oc --kubeconfig "$HUB_KUBECONFIG" -n "$ns" get placement "$placement" >/dev/null

cat <<EOF_YAML | oc --kubeconfig "$HUB_KUBECONFIG" apply -f -
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: portworx-pure-binding
  namespace: ${ns}
placementRef:
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
  name: ${placement}
subjects:
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: portworx-pure-node-prep
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: portworx-operator
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: portworx-pure-secret
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: portworx-flasharray-storagecluster
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: portworx-openshift-console-plugin
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: portworx-hcp-storageclasses
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: portworx-hcp-storageclasses-binding
  namespace: ${ns}
placementRef:
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
  name: ${placement}
subjects:
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: portworx-hcp-storageclasses
EOF_YAML

echo
oc --kubeconfig "$HUB_KUBECONFIG" -n "$ns" get placementbinding portworx-pure-binding portworx-hcp-storageclasses-binding -o yaml | \
  egrep 'name:|subjects:|kind: Policy' || true

echo
echo "Portworx policy bindings repaired. Give RHACM a minute to refresh the policy list."
