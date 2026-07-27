#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/inventory-env.sh
source scripts/lib/inventory-env.sh

show() {
  local label="$1"
  local path="$2"
  printf '%-34s %s\n' "$label" "$(inventory_value "$path")"
}

printf 'Environment source: %s\n\n' "$ENV_MAIN_FILE"
show 'OpenShift release' ocp_release_version
show 'Hub cluster name' cluster_name
show 'Base domain' base_domain
show 'Machine network' machine_cidr
show 'Machine VLAN' machine_vlan_id
show 'Gateway' gateway
show 'DNS server' ad_dns_server
show 'SNO node address' sno_node.ip
show 'vCenter' vcenter_hostname
show 'ESXi host' vsphere_esxi_hostname
show 'Bastion' bastion_ip
show 'Site-A cluster' bm_cluster_name
show 'Site-A API VIP' bm_api_vip
show 'Site-A ingress VIP' bm_ingress_vip
show 'Site-A HCP LB range' site_a_hcp_metallb_range
show 'Site-B cluster' site_b_cluster_name
show 'Site-B API VIP' site_b_api_vip
show 'Site-B ingress VIP' site_b_ingress_vip
show 'Site-B HCP LB range' site_b_hcp_metallb_range
show 'Primary FlashArray' pure_flasharray_mgmt_endpoint
show 'Secondary FlashArray' pure_flasharray_secondary_mgmt_endpoint

printf '\nBare-metal nodes:\n'
python3 - "$ENV_MAIN_FILE" <<'PY'
import sys
from pathlib import Path
import yaml

data = yaml.safe_load(Path(sys.argv[1]).read_text()) or {}
seen = set()
for group in ("bm_nodes", "site_b_nodes"):
    for node in data.get(group, []):
        key = (node.get("name"), node.get("bmc_ip"), node.get("ip"))
        if key in seen:
            continue
        seen.add(key)
        print(f"  {node.get('name')}: BMC={node.get('bmc_ip')} OS={node.get('ip')} MAC={node.get('boot_mac')}")
PY

printf '\nHCP tenants:\n'
# shellcheck source=scripts/lib/hcp-tenants.sh
source scripts/lib/hcp-tenants.sh
hcp_tenants | awk -F'|' '{printf "  %s: site=%s clusterCIDR=%s serviceCIDR=%s extraDisks=%s\n", $2, $1, $4, $5, $6}'
