#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/inventory-env.sh
source scripts/lib/inventory-env.sh

CLUSTER_NAME="$ENV_SITE_A_CLUSTER_NAME"
POLICY_NS="$ENV_SITE_A_POLICY_NAMESPACE"
CLUSTERSET="$ENV_SITE_A_CLUSTERSET"
CONFIRM_VAR="CONFIRM_DELETE_SITE_A"

HUB_KUBECONFIG="${HUB_KUBECONFIG:-$ENV_HUB_KUBECONFIG}"

if [[ ! -s "$HUB_KUBECONFIG" ]]; then
  echo "Hub kubeconfig not found: $HUB_KUBECONFIG" >&2
  exit 1
fi

if [[ "${CONFIRM_DELETE_SITE_A:-false}" != "true" ]]; then
  cat >&2 <<MSG
Refusing to delete $CLUSTER_NAME without confirmation.

This removes the RHACM/Assisted Installer objects for $CLUSTER_NAME from the hub.
It does not wipe disks or uninstall Portworx directly. If HCPs exist on this site,
run ./scripts/hcp-delete.sh first.

Run again with:
  CONFIRM_DELETE_SITE_A=true ./scripts/site-a-delete.sh
MSG
  exit 1
fi

echo "Deleting $CLUSTER_NAME from RHACM hub using: $HUB_KUBECONFIG"
oc --kubeconfig "$HUB_KUBECONFIG" whoami --show-server

echo "# Delete ClusterDeployment and Assisted Installer resources"
oc --kubeconfig "$HUB_KUBECONFIG" -n "$CLUSTER_NAME" delete clusterdeployment "$CLUSTER_NAME" --ignore-not-found --wait=false || true
oc --kubeconfig "$HUB_KUBECONFIG" -n "$CLUSTER_NAME" delete agentclusterinstall "$CLUSTER_NAME" --ignore-not-found --wait=false || true
oc --kubeconfig "$HUB_KUBECONFIG" -n "$CLUSTER_NAME" delete infraenv "$CLUSTER_NAME" --ignore-not-found --wait=false || true
oc --kubeconfig "$HUB_KUBECONFIG" -n "$CLUSTER_NAME" delete bmh --all --ignore-not-found --wait=false || true
oc --kubeconfig "$HUB_KUBECONFIG" -n "$CLUSTER_NAME" delete nmstateconfig --all --ignore-not-found --wait=false || true

echo "# Delete RHACM import/add-on objects"
oc --kubeconfig "$HUB_KUBECONFIG" -n "$CLUSTER_NAME" delete klusterletaddonconfig "$CLUSTER_NAME" --ignore-not-found --wait=false || true
oc --kubeconfig "$HUB_KUBECONFIG" delete managedcluster "$CLUSTER_NAME" --ignore-not-found --wait=false || true

echo "# Delete policy namespace and managed cluster set for clean recreation"
oc --kubeconfig "$HUB_KUBECONFIG" delete ns "$POLICY_NS" --ignore-not-found --wait=false || true
oc --kubeconfig "$HUB_KUBECONFIG" delete managedclusterset "$CLUSTERSET" --ignore-not-found --wait=false || true

echo "# Delete cluster namespace last"
oc --kubeconfig "$HUB_KUBECONFIG" delete ns "$CLUSTER_NAME" --ignore-not-found --wait=false || true

echo
cat <<MSG
Delete requested for $CLUSTER_NAME.

Watch cleanup with:
  oc --kubeconfig "$HUB_KUBECONFIG" get ns $CLUSTER_NAME $POLICY_NS
  oc --kubeconfig "$HUB_KUBECONFIG" get managedcluster $CLUSTER_NAME
MSG
