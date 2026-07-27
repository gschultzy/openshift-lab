#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/hcp-tenants.sh
source scripts/lib/hcp-tenants.sh

ROOT_DIR="$PWD"
SITE_A_KUBECONFIG="${SITE_A_KUBECONFIG:-$ENV_SITE_A_KUBECONFIG}"
SITE_B_KUBECONFIG="${SITE_B_KUBECONFIG:-$ENV_SITE_B_KUBECONFIG}"
HCP_NAMESPACE="${HCP_NAMESPACE:-clusters}"
HCP_STORAGE_CLASS="${HCP_STORAGE_CLASS:-hcp-pxe-boot}"

check_site() {
  local label="$1"
  local kubeconfig="$2"
  local namespace="$3"

  echo
  echo "######################################################################"
  echo "# $label"
  echo "######################################################################"
  echo
  echo "# Portworx"
  oc --kubeconfig "$kubeconfig" -n portworx get storagecluster,pods | egrep -i 'NAME|px-cluster-flasharray|portworx-api|px-csi|px-plugin|Running' || true
  echo
  echo "# StorageClass / StorageProfile"
  oc --kubeconfig "$kubeconfig" get sc "$HCP_STORAGE_CLASS" -o yaml | egrep -i 'name:|provisioner:|volumeBindingMode:|allowVolumeExpansion:|is-default' || true
  oc --kubeconfig "$kubeconfig" get storageprofile "$HCP_STORAGE_CLASS" -o yaml | egrep -A8 -i 'claimPropertySets|accessModes|volumeMode' || true
  echo
  echo "# HCP resources"
  oc --kubeconfig "$kubeconfig" -n "$namespace" get hostedcluster,nodepool,pvc || true
}

check_tenant() {
  local label="$1"
  local kubeconfig="$2"
  local namespace="$3"
  local name="$4"

  echo
  echo "# ${label} ${name} NodePool storage fields"
  oc --kubeconfig "$kubeconfig" -n "$namespace" get nodepool "$name" -o yaml | egrep -A16 -i 'platform:|kubevirt:|rootVolume|storageClass|accessModes|volumeMode' || true
  echo
  echo "# ${label} ${name} hosted control-plane namespace"
  oc --kubeconfig "$kubeconfig" -n "clusters-$name" get pods,pvc || true
}

check_site "Site-A" "$SITE_A_KUBECONFIG" "$HCP_NAMESPACE"
while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
  [[ "$site" == "site-a" ]] || continue
  check_tenant "Site-A" "$SITE_A_KUBECONFIG" "$HCP_NAMESPACE" "$name"
done < <(hcp_tenants)

check_site "Site-B" "$SITE_B_KUBECONFIG" "$HCP_NAMESPACE"
while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
  [[ "$site" == "site-b" ]] || continue
  check_tenant "Site-B" "$SITE_B_KUBECONFIG" "$HCP_NAMESPACE" "$name"
done < <(hcp_tenants)
