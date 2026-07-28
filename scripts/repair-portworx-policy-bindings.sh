#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/inventory-env.sh
source scripts/lib/inventory-env.sh

HUB_KUBECONFIG="${HUB_KUBECONFIG:-$ENV_HUB_KUBECONFIG}"
export KUBECONFIG="$HUB_KUBECONFIG"

[[ -f "$HUB_KUBECONFIG" ]] || { echo "Hub kubeconfig not found: $HUB_KUBECONFIG" >&2; exit 1; }
./scripts/ensure-hub-kubeconfig.sh >/dev/null 2>&1 || true

api_server="$(oc --kubeconfig "$HUB_KUBECONFIG" whoami --show-server)"
if [[ "$api_server" != *"$ENV_HUB_API_HOST"* ]]; then
  echo "Refusing to repair Portworx policy bindings because this is not the configured hub." >&2
  echo "Current API server: $api_server" >&2
  echo "Expected API host: $ENV_HUB_API_HOST" >&2
  exit 1
fi

ns="portworx-pure-policies"
oc --kubeconfig "$HUB_KUBECONFIG" get ns "$ns" >/dev/null

for site in site-a site-b; do
  placement="portworx-pure-${site}-placement"
  binding="portworx-pure-${site}-binding"
  sc_binding="portworx-hcp-storageclasses-binding-${site}"
  oc --kubeconfig "$HUB_KUBECONFIG" -n "$ns" get placement "$placement" >/dev/null

  cat <<EOF_YAML | oc --kubeconfig "$HUB_KUBECONFIG" apply -f -
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: ${binding}
  namespace: ${ns}
placementRef:
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
  name: ${placement}
subjects:
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: portworx-pure-node-prep-${site}
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: portworx-operator-${site}
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: portworx-pure-secret-${site}
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: portworx-pure-storagecluster-${site}
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: portworx-openshift-console-plugin-${site}
---
apiVersion: policy.open-cluster-management.io/v1
kind: PlacementBinding
metadata:
  name: ${sc_binding}
  namespace: ${ns}
placementRef:
  apiGroup: cluster.open-cluster-management.io
  kind: Placement
  name: ${placement}
subjects:
  - apiGroup: policy.open-cluster-management.io
    kind: Policy
    name: portworx-hcp-storageclasses-${site}
EOF_YAML
done

echo
oc --kubeconfig "$HUB_KUBECONFIG" -n "$ns" get placementbinding -o wide
echo
echo "Site-specific Portworx policy bindings repaired."
