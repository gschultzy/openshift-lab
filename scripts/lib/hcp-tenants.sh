#!/usr/bin/env bash
# Shared tenant list for HCP lifecycle scripts.
#
# Format per line:
#   site|hostedcluster_name|rhacm_managedcluster_name|cluster_cidr|service_cidr|extra_disks|tenant_px_storage_class|guest_storage_class
#
# - extra_disks=true is for the PX tenant shape. It creates the extra FADA disks used by PX storage pools.
# - extra_disks=false is for the plain KubeVirt tenant shape.
# - RHACM ManagedCluster name intentionally matches the HostedCluster name. This removes the old
#   site-a-hcp-t1-px / site-b-hcp-t1-px naming convention.

DEFAULT_HCP_TENANTS=$(cat <<'TENANTS'
site-a|site-a-hcp-t1-px|site-a-hcp-t1-px|10.144.0.0/14|172.32.0.0/16|true|hcp-fada-data|hcp-pxe-data
site-a|site-a-hcp-t2-kv|site-a-hcp-t2-kv|10.148.0.0/14|172.33.0.0/16|false|hcp-fada-data|hcp-pxe-data
site-b|site-b-hcp-t1-px|site-b-hcp-t1-px|10.152.0.0/14|172.34.0.0/16|true|hcp-fada-data|hcp-pxe-data
site-b|site-b-hcp-t2-kv|site-b-hcp-t2-kv|10.156.0.0/14|172.35.0.0/16|false|hcp-fada-data|hcp-pxe-data
TENANTS
)

hcp_tenants() {
  if [[ -n "${HCP_TENANTS:-}" ]]; then
    printf '%s\n' "$HCP_TENANTS" | tr ';' '\n' | awk 'NF && $0 !~ /^#/ {print}'
  else
    printf '%s\n' "$DEFAULT_HCP_TENANTS" | awk 'NF && $0 !~ /^#/ {print}'
  fi
}

hcp_tenants_for_site() {
  local wanted_site="$1"
  hcp_tenants | awk -F'|' -v s="$wanted_site" '$1 == s {print}'
}

hcp_tenant_count() {
  hcp_tenants | wc -l | tr -d ' '
}

hcp_tenant_site_label() {
  case "$1" in
    site-a) printf 'Site-A' ;;
    site-b) printf 'Site-B' ;;
    *) printf '%s' "$1" ;;
  esac
}

hcp_tenant_ansible_prefix() {
  case "$1" in
    site-a) printf 'site_a' ;;
    site-b) printf 'site_b' ;;
    *) echo "ERROR: unknown HCP tenant site '$1'" >&2; return 1 ;;
  esac
}

hcp_tenant_site_kubeconfig() {
  local site="$1"
  local root_dir="${2:-$PWD}"
  case "$site" in
    site-a) printf '%s/build/hub-sno/site-a/auth/kubeconfig' "$root_dir" ;;
    site-b) printf '%s/build/hub-sno/site-b/auth/kubeconfig' "$root_dir" ;;
    *) echo "ERROR: unknown HCP tenant site '$site'" >&2; return 1 ;;
  esac
}

hcp_tenant_playbook() {
  case "$1" in
    site-a) printf 'playbooks/14_create_site_a_hcp_kubevirt_cluster.yml' ;;
    site-b) printf 'playbooks/14_create_site_b_hcp_kubevirt_cluster.yml' ;;
    *) echo "ERROR: unknown HCP tenant site '$1'" >&2; return 1 ;;
  esac
}

hcp_tenant_kubeconfig_path() {
  local out_dir="$1"
  local name="$2"
  printf '%s/%s.kubeconfig' "$out_dir" "$name"
}
