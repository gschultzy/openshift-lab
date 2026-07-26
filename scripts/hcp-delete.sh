#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/hcp-tenants.sh
source scripts/lib/hcp-tenants.sh

export HUB_KUBECONFIG="${HUB_KUBECONFIG:-$PWD/build/hub-sno/install/auth/kubeconfig}"
export HCP_NAMESPACE="${HCP_NAMESPACE:-clusters}"
# This is a lab lifecycle wrapper; make delete remove stale import namespaces if RHACM leaves them Terminating.
export HCP_FORCE_CLEANUP="${HCP_FORCE_CLEANUP:-true}"

cat <<MSG
Deleting lab HCP tenants from namespace ${HCP_NAMESPACE}:
MSG
hcp_tenants | while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
  printf '  %-6s HostedCluster=%-18s ManagedCluster=%s\n' "$site" "$name" "$mc"
done
cat <<MSG

MSG

exec ./scripts/cleanup-hcp-clusters.sh "$@"
