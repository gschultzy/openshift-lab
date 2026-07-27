#!/usr/bin/env bash
# Shared environment values loaded from inventories/env/group_vars/all/main.yml.
# Source this file; do not execute it directly.

if [[ -z "${ENV_REPO_ROOT:-}" ]]; then
  ENV_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
ENV_MAIN_FILE="${ENV_MAIN_FILE:-$ENV_REPO_ROOT/inventories/env/group_vars/all/main.yml}"
ENV_VALUE_HELPER="$ENV_REPO_ROOT/scripts/lib/inventory-value.py"

inventory_value() {
  "$ENV_VALUE_HELPER" --file "$ENV_MAIN_FILE" "$@"
}

ENV_INVENTORY_RELATIVE="${ENV_INVENTORY_RELATIVE:-$(inventory_value inventory_file)}"
ENV_INVENTORY_FILE="${ENV_INVENTORY_FILE:-$ENV_REPO_ROOT/$ENV_INVENTORY_RELATIVE}"
ENV_CLUSTER_NAME="${ENV_CLUSTER_NAME:-$(inventory_value cluster_name)}"
ENV_BASE_DOMAIN="${ENV_BASE_DOMAIN:-$(inventory_value base_domain)}"
ENV_CLUSTER_FQDN="${ENV_CLUSTER_FQDN:-${ENV_CLUSTER_NAME}.${ENV_BASE_DOMAIN}}"
ENV_HUB_API_HOST="${ENV_HUB_API_HOST:-api.${ENV_CLUSTER_FQDN}}"
ENV_BUILD_ROOT="${ENV_BUILD_ROOT:-$ENV_REPO_ROOT/build/$ENV_CLUSTER_NAME}"
ENV_HUB_KUBECONFIG="${ENV_HUB_KUBECONFIG:-$ENV_BUILD_ROOT/install/auth/kubeconfig}"
ENV_SITE_A_CLUSTER_NAME="${ENV_SITE_A_CLUSTER_NAME:-$(inventory_value bm_cluster_name)}"
ENV_SITE_B_CLUSTER_NAME="${ENV_SITE_B_CLUSTER_NAME:-$(inventory_value site_b_cluster_name)}"
ENV_SITE_A_CLUSTERSET="${ENV_SITE_A_CLUSTERSET:-$(inventory_value bm_clusterset)}"
ENV_SITE_B_CLUSTERSET="${ENV_SITE_B_CLUSTERSET:-$(inventory_value site_b_clusterset)}"
ENV_SITE_A_POLICY_NAMESPACE="${ENV_SITE_A_POLICY_NAMESPACE:-$(inventory_value site_a_policy_namespace)}"
ENV_SITE_B_POLICY_NAMESPACE="${ENV_SITE_B_POLICY_NAMESPACE:-$(inventory_value site_b_policy_namespace)}"
ENV_HCP_NAMESPACE="${ENV_HCP_NAMESPACE:-$(inventory_value site_a_hcp_namespace)}"
ENV_PORTWORX_POLICY_NAMESPACE="${ENV_PORTWORX_POLICY_NAMESPACE:-$(inventory_value portworx_pure_policy_namespace)}"
ENV_SITE_A_KUBECONFIG="${ENV_SITE_A_KUBECONFIG:-$ENV_BUILD_ROOT/$ENV_SITE_A_CLUSTER_NAME/auth/kubeconfig}"
ENV_SITE_B_KUBECONFIG="${ENV_SITE_B_KUBECONFIG:-$ENV_BUILD_ROOT/$ENV_SITE_B_CLUSTER_NAME/auth/kubeconfig}"
ENV_HCP_KUBECONFIG_DIR="${ENV_HCP_KUBECONFIG_DIR:-$ENV_BUILD_ROOT/hcp-kubeconfigs}"
