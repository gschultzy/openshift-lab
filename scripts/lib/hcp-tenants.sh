#!/usr/bin/env bash
# Shared HCP tenant list for lifecycle scripts.
# Environment-specific tenant names, CIDRs, and storage classes are read from
# inventories/env/group_vars/all/main.yml under hcp_tenants.

# shellcheck source=scripts/lib/inventory-env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/inventory-env.sh"

hcp_tenants() {
  if [[ -n "${HCP_TENANTS:-}" ]]; then
    printf '%s\n' "$HCP_TENANTS" | tr ';' '\n' | awk 'NF && $0 !~ /^#/ {print}'
    return
  fi

  python3 - "$ENV_MAIN_FILE" <<'PY'
import sys
from pathlib import Path
import yaml

path = Path(sys.argv[1])
data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
for tenant in data.get("hcp_tenants", []):
    fields = (
        tenant.get("site", ""),
        tenant.get("name", ""),
        tenant.get("managed_cluster_name", tenant.get("name", "")),
        tenant.get("cluster_cidr", ""),
        tenant.get("service_cidr", ""),
        str(bool(tenant.get("enable_extra_disks", False))).lower(),
        tenant.get("tenant_px_storage_class", ""),
        tenant.get("guest_storage_class", ""),
    )
    print("|".join(str(value) for value in fields))
PY
}

hcp_tenants_for_site() {
  local wanted_site="$1"
  hcp_tenants | awk -F'|' -v s="$wanted_site" '$1 == s {print}'
}

hcp_tenant_count() {
  hcp_tenants | wc -l | tr -d ' '
}

hcp_tenant_site_label() {
  local site="$1"
  if [[ "$site" == "$ENV_SITE_A_CLUSTER_NAME" ]]; then
    inventory_value bm_cluster_display_name
  elif [[ "$site" == "$ENV_SITE_B_CLUSTER_NAME" ]]; then
    inventory_value site_b_cluster_display_name
  else
    printf '%s' "$site"
  fi
}

hcp_tenant_ansible_prefix() {
  local site="$1"
  if [[ "$site" == "$ENV_SITE_A_CLUSTER_NAME" ]]; then
    printf 'site_a'
  elif [[ "$site" == "$ENV_SITE_B_CLUSTER_NAME" ]]; then
    printf 'site_b'
  else
    echo "ERROR: unknown HCP tenant site '$site'" >&2
    return 1
  fi
}

hcp_tenant_site_kubeconfig() {
  local site="$1"
  if [[ "$site" == "$ENV_SITE_A_CLUSTER_NAME" ]]; then
    printf '%s' "$ENV_SITE_A_KUBECONFIG"
  elif [[ "$site" == "$ENV_SITE_B_CLUSTER_NAME" ]]; then
    printf '%s' "$ENV_SITE_B_KUBECONFIG"
  else
    echo "ERROR: unknown HCP tenant site '$site'" >&2
    return 1
  fi
}

hcp_tenant_playbook() {
  local site="$1"
  if [[ "$site" == "$ENV_SITE_A_CLUSTER_NAME" ]]; then
    printf 'playbooks/14_create_site_a_hcp_kubevirt_cluster.yml'
  elif [[ "$site" == "$ENV_SITE_B_CLUSTER_NAME" ]]; then
    printf 'playbooks/14_create_site_b_hcp_kubevirt_cluster.yml'
  else
    echo "ERROR: unknown HCP tenant site '$site'" >&2
    return 1
  fi
}

hcp_tenant_kubeconfig_path() {
  local out_dir="$1"
  local name="$2"
  printf '%s/%s.kubeconfig' "$out_dir" "$name"
}
