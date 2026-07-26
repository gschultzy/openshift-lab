#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/hcp-tenants.sh
source scripts/lib/hcp-tenants.sh

HUB_KUBECONFIG="${HUB_KUBECONFIG:-$PWD/build/hub-sno/install/auth/kubeconfig}"

hub_oc() { oc --kubeconfig "$HUB_KUBECONFIG" "$@"; }

echo "Hub API: $(hub_oc whoami --show-server 2>/dev/null || true)"
echo
echo "# Managed clusters"
hub_oc get managedcluster -o wide || true

while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
  echo
  echo "# ${mc} conditions"
  if hub_oc get managedcluster "$mc" >/dev/null 2>&1; then
    hub_oc get managedcluster "$mc" -o=jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}' || true
    echo
    echo "# ${mc} import namespace pods/secrets"
    hub_oc -n "$mc" get pods,secrets 2>/dev/null || true
  else
    echo "ManagedCluster ${mc} not found on the hub."
  fi
done < <(hcp_tenants)
