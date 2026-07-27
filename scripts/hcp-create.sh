#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .venv/bin/activate ]]; then
  # shellcheck source=/dev/null
  source .venv/bin/activate
else
  echo "Missing .venv. Run ./scripts/bootstrap-ubuntu-24.04.sh first on the Ubuntu bastion." >&2
  exit 1
fi

# shellcheck source=scripts/lib/hcp-tenants.sh
source scripts/lib/hcp-tenants.sh

INV="${INV:-$ENV_INVENTORY_FILE}"
ROOT_DIR="$PWD"

./scripts/assert-release-baseline.sh
./scripts/sync-openshift-tools.sh

if [[ -n "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ]]; then
  VAULT_ARGS=(--vault-password-file "$ANSIBLE_VAULT_PASSWORD_FILE")
else
  VAULT_PASSWORD_FILE_TMP="$(mktemp)"
  chmod 600 "$VAULT_PASSWORD_FILE_TMP"
  trap 'rm -f "$VAULT_PASSWORD_FILE_TMP"' EXIT

  read -r -s -p "Vault password: " VAULT_PASSWORD
  echo
  printf '%s\n' "$VAULT_PASSWORD" > "$VAULT_PASSWORD_FILE_TMP"
  unset VAULT_PASSWORD

  VAULT_ARGS=(--vault-password-file "$VAULT_PASSWORD_FILE_TMP")
fi

export HUB_KUBECONFIG="${HUB_KUBECONFIG:-$ENV_HUB_KUBECONFIG}"
export KUBECONFIG="$HUB_KUBECONFIG"

# Common HCP namespace and storage defaults.
export HCP_NAMESPACE="${HCP_NAMESPACE:-$ENV_HCP_NAMESPACE}"
export HCP_ETCD_STORAGE_CLASS="${HCP_ETCD_STORAGE_CLASS:-${HCP_STORAGE_CLASS:-hcp-pxe-etcd-pxfast}}"
export HCP_ROOT_STORAGE_CLASS="${HCP_ROOT_STORAGE_CLASS:-${HCP_STORAGE_CLASS:-hcp-pxe-boot}}"
export HCP_DATA_STORAGE_CLASS="${HCP_DATA_STORAGE_CLASS:-${HCP_STORAGE_CLASS:-hcp-pxe-data}}"
export HCP_GUEST_STORAGE_CLASS="${HCP_GUEST_STORAGE_CLASS:-$HCP_DATA_STORAGE_CLASS}"
export HCP_TENANT_PX_STORAGE_CLASS="${HCP_TENANT_PX_STORAGE_CLASS:-hcp-fada-data}"
export HCP_EXTRA_DISK_STORAGE_CLASS="${HCP_EXTRA_DISK_STORAGE_CLASS:-$HCP_TENANT_PX_STORAGE_CLASS}"
export HCP_STORAGE_CLASS="$HCP_ROOT_STORAGE_CLASS"

export HCP_ROOT_VOLUME_SIZE="${HCP_ROOT_VOLUME_SIZE:-64}"
export HCP_ROOT_VOLUME_ACCESS_MODES="${HCP_ROOT_VOLUME_ACCESS_MODES:-ReadWriteMany}"
export HCP_ROOT_VOLUME_VOLUME_MODE="${HCP_ROOT_VOLUME_VOLUME_MODE:-Block}"
export HCP_ROOT_VOLUME_CACHE="${HCP_ROOT_VOLUME_CACHE:-false}"
export HCP_RECREATE="${HCP_RECREATE:-false}"
export HCP_NODEPOOL_REPLICAS="${HCP_NODEPOOL_REPLICAS:-3}"
export HCP_WORKER_CORES="${HCP_WORKER_CORES:-8}"
export HCP_WORKER_MEMORY="${HCP_WORKER_MEMORY:-8Gi}"
export HCP_CHANNEL="${HCP_CHANNEL:-stable-4.21}"
export HCP_ETCD_VOLUME_SIZE="${HCP_ETCD_VOLUME_SIZE:-8Gi}"
export HCP_KUBECONFIG_WAIT_RETRIES="${HCP_KUBECONFIG_WAIT_RETRIES:-90}"
export HCP_KUBECONFIG_WAIT_DELAY="${HCP_KUBECONFIG_WAIT_DELAY:-10}"

# Creation is one step: create/export/import all HCP guest clusters into RHACM.
# Keep false so import resources are created even while the guest cluster is still settling.
export HCP_IMPORT_SKIP_NOT_READY="${HCP_IMPORT_SKIP_NOT_READY:-false}"
export HCP_IMPORT_WAIT="${HCP_IMPORT_WAIT:-true}"
export HCP_IMPORT_FORCE_CLEANUP="${HCP_IMPORT_FORCE_CLEANUP:-true}"
# Lab fallback: when RHACM hypershift-addon gets stuck before creating CRDs,
# bootstrap the HyperShift operator on the spoke with `hcp install render`.
export HCP_DIRECT_HYPERSHIFT_INSTALL="${HCP_DIRECT_HYPERSHIFT_INSTALL:-true}"

SITE_A_KUBECONFIG="${SITE_A_KUBECONFIG:-$ENV_SITE_A_KUBECONFIG}"
SITE_B_KUBECONFIG="${SITE_B_KUBECONFIG:-$ENV_SITE_B_KUBECONFIG}"
HCP_KUBECONFIG_OUT_DIR="${HCP_KUBECONFIG_OUT_DIR:-$ENV_HCP_KUBECONFIG_DIR}"

say() { printf '\n### %s\n' "$*"; }

COMMON_EXTRA_VARS=(
  -e "portworx_hcp_root_volume_storage_class=$HCP_ROOT_STORAGE_CLASS"
  -e "portworx_hcp_etcd_storage_class=$HCP_ETCD_STORAGE_CLASS"
  -e "portworx_hcp_passthrough_infra_storage_class=$HCP_DATA_STORAGE_CLASS"
  -e "portworx_hcp_guest_storage_class=$HCP_GUEST_STORAGE_CLASS"
  -e "portworx_hcp_infra_storage_class=$HCP_ROOT_STORAGE_CLASS"
  -e "portworx_hcp_root_volume_size=$HCP_ROOT_VOLUME_SIZE"
  -e "portworx_hcp_root_volume_access_modes=$HCP_ROOT_VOLUME_ACCESS_MODES"
  -e "portworx_hcp_root_volume_volume_mode=$HCP_ROOT_VOLUME_VOLUME_MODE"
  -e "portworx_hcp_enable_root_volume_cache=$HCP_ROOT_VOLUME_CACHE"
  -e "hcp_direct_hypershift_install=$HCP_DIRECT_HYPERSHIFT_INSTALL"
)

tenant_extra_vars() {
  local site="$1" name="$2" cluster_cidr="$3" service_cidr="$4" extra_disks="$5" tenant_px_sc="$6" guest_sc="$7"
  local prefix
  prefix="$(hcp_tenant_ansible_prefix "$site")"

  printf '%s\0' \
    -e "${prefix}_hcp_cluster_name=$name" \
    -e "${prefix}_hcp_namespace=$HCP_NAMESPACE" \
    -e "${prefix}_hcp_channel=$HCP_CHANNEL" \
    -e "${prefix}_hcp_cluster_cidr=$cluster_cidr" \
    -e "${prefix}_hcp_service_cidr=$service_cidr" \
    -e "${prefix}_hcp_recreate=$HCP_RECREATE" \
    -e "${prefix}_hcp_nodepool_replicas=$HCP_NODEPOOL_REPLICAS" \
    -e "${prefix}_hcp_worker_cores=$HCP_WORKER_CORES" \
    -e "${prefix}_hcp_worker_memory=$HCP_WORKER_MEMORY" \
    -e "${prefix}_hcp_etcd_volume_size=$HCP_ETCD_VOLUME_SIZE" \
    -e "${prefix}_hcp_etcd_storage_class=$HCP_ETCD_STORAGE_CLASS" \
    -e "${prefix}_hcp_root_volume_storage_class=$HCP_ROOT_STORAGE_CLASS" \
    -e "${prefix}_hcp_root_volume_size=$HCP_ROOT_VOLUME_SIZE" \
    -e "${prefix}_hcp_root_volume_access_modes=$HCP_ROOT_VOLUME_ACCESS_MODES" \
    -e "${prefix}_hcp_root_volume_volume_mode=$HCP_ROOT_VOLUME_VOLUME_MODE" \
    -e "${prefix}_hcp_enable_root_volume_cache=$HCP_ROOT_VOLUME_CACHE" \
    -e "${prefix}_hcp_passthrough_infra_storage_class=$HCP_DATA_STORAGE_CLASS" \
    -e "${prefix}_hcp_passthrough_guest_storage_class=$guest_sc" \
    -e "${prefix}_hcp_tenant_px_storage_class=$tenant_px_sc" \
    -e "${prefix}_hcp_extra_disk_storage_class=$tenant_px_sc" \
    -e "${prefix}_hcp_enable_extra_disks=$extra_disks"
}

read_tenant_extra_vars() {
  local -n out_ref=$1
  shift
  out_ref=()
  while IFS= read -r -d '' item; do
    out_ref+=("$item")
  done < <(tenant_extra_vars "$@")
}

wait_for_admin_kubeconfig_secret() {
  local label="$1"
  local kubeconfig="$2"
  local ns="$3"
  local name="$4"

  say "Wait for ${label} admin kubeconfig secret"
  for i in $(seq 1 "$HCP_KUBECONFIG_WAIT_RETRIES"); do
    for candidate_ns in "$ns" "clusters-${name}"; do
      for candidate in "${name}-admin-kubeconfig" "admin-kubeconfig"; do
        if oc --kubeconfig "$kubeconfig" -n "$candidate_ns" get secret "$candidate" >/dev/null 2>&1; then
          echo "Found ${label} admin kubeconfig secret: ${candidate_ns}/${candidate}"
          return 0
        fi
      done
    done

    if (( i == 1 || i % 6 == 0 )); then
      echo "Waiting for ${label} admin kubeconfig secret: attempt ${i}/${HCP_KUBECONFIG_WAIT_RETRIES}"
      oc --kubeconfig "$kubeconfig" -n "$ns" get hostedcluster "$name" 2>/dev/null || true
      for candidate_ns in "$ns" "clusters-${name}"; do
        oc --kubeconfig "$kubeconfig" -n "$candidate_ns" get secret 2>/dev/null | egrep -i "${name}|admin|kubeconfig|kubeadmin" || true
      done
    fi
    sleep "$HCP_KUBECONFIG_WAIT_DELAY"
  done

  echo "ERROR: Timed out waiting for ${label} admin kubeconfig secret in ${ns}." >&2
  return 1
}

read_kubeadmin_password() {
  local kubeconfig="$1"
  local ns="$2"
  local name="$3"
  local encoded=""

  for candidate_ns in "$ns" "clusters-${name}"; do
    for candidate_secret in "${name}-kubeadmin-password" "kubeadmin-password" "${name}-admin-password"; do
      if oc --kubeconfig "$kubeconfig" -n "$candidate_ns" get secret "$candidate_secret" >/dev/null 2>&1; then
        for candidate_key in password kubeadmin-password; do
          encoded="$(oc --kubeconfig "$kubeconfig" -n "$candidate_ns" get secret "$candidate_secret" -o json 2>/dev/null | jq -r --arg k "$candidate_key" '.data[$k] // empty' || true)"
          if [[ -n "$encoded" ]]; then
            printf '%s' "$encoded" | base64 -d 2>/dev/null || true
            return 0
          fi
        done
      fi
    done
  done

  return 1
}

print_access_summary() {
  local site_label="$1"
  local hcp_name="$2"
  local mc_name="$3"
  local site_kubeconfig="$4"
  local hcp_ns="$5"
  local guest_kubeconfig="$6"
  local password=""
  local api=""

  api="$(oc --kubeconfig "$guest_kubeconfig" whoami --show-server 2>/dev/null || true)"
  password="$(read_kubeadmin_password "$site_kubeconfig" "$hcp_ns" "$hcp_name" || true)"

  printf '\n%s\n' "${site_label}"
  printf '  HostedCluster:       %s/%s\n' "$hcp_ns" "$hcp_name"
  printf '  RHACM ManagedCluster: %s\n' "$mc_name"
  printf '  Guest kubeconfig:     %s\n' "$guest_kubeconfig"
  printf '  Guest API:            %s\n' "${api:-not ready yet}"
  if [[ -n "$password" ]]; then
    printf '  kubeadmin password:   %s\n' "$password"
  else
    printf '  kubeadmin password:   not available yet; check secret %s/%s-kubeadmin-password\n' "$hcp_ns" "$hcp_name"
  fi
}

say "HCP create/import plan"
echo "Hub kubeconfig:        $HUB_KUBECONFIG"
echo "HCP namespace:         $HCP_NAMESPACE"
echo "HCP channel:           $HCP_CHANNEL"
echo "HCP release:           inventory ocp_release_version default"
echo "HCP etcd StorageClass: $HCP_ETCD_STORAGE_CLASS"
echo "HCP root StorageClass: $HCP_ROOT_STORAGE_CLASS"
echo "HCP data StorageClass: $HCP_DATA_STORAGE_CLASS"
echo "Guest StorageClass:    $HCP_GUEST_STORAGE_CLASS"
echo "Tenant PX StorageClass:$HCP_TENANT_PX_STORAGE_CLASS"
echo "NodePool VM size:      $HCP_WORKER_CORES cores / $HCP_WORKER_MEMORY"
echo "NodePool replicas:     $HCP_NODEPOOL_REPLICAS"
echo "Recreate if existing:  $HCP_RECREATE"
echo "Import into RHACM:     true"
echo "Direct HCP operator bootstrap: $HCP_DIRECT_HYPERSHIFT_INSTALL"
echo
echo "Tenants:"
hcp_tenants | while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
  printf '  %-6s HostedCluster=%-18s RHACM=%-18s pod=%-15s svc=%-15s extra_disks=%s\n' \
    "$site" "$name" "$mc" "$cluster_cidr" "$service_cidr" "$extra_disks"
done

./scripts/fix-acm-hypershift-local-hosting.sh
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/17_validate_hub_context.yml
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" "${COMMON_EXTRA_VARS[@]}" playbooks/18_check_spoke_mce_conflicts.yml
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" "${COMMON_EXTRA_VARS[@]}" playbooks/17_configure_acm_mce_integration.yml
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" "${COMMON_EXTRA_VARS[@]}" playbooks/16_ensure_hypershift_operator_on_spokes.yml

# Ensure the Portworx HCP StorageClass policy is present before the spoke-side
# preparation step validates/patches StorageProfiles and HyperConverged. This
# only applies the HCP StorageClass policy; it does not reinstall Portworx.
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" "${COMMON_EXTRA_VARS[@]}" playbooks/20_apply_portworx_pure_policies.yml \
  -e portworx_pure_apply_node_prep=false \
  -e portworx_pure_apply_operator=false \
  -e portworx_pure_apply_storagecluster=false \
  -e portworx_enable_openshift_console_plugin=false \
  -e portworx_pure_apply_hcp_storageclasses=true

ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" "${COMMON_EXTRA_VARS[@]}" playbooks/27_prepare_hcp_portworx_storage_on_spokes.yml

say "Prepare Site-A HCP prerequisites"
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" "${COMMON_EXTRA_VARS[@]}" playbooks/12_apply_site_a_hcp_policies.yml
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" "${COMMON_EXTRA_VARS[@]}" playbooks/12_fix_site_a_policy_placement.yml
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" "${COMMON_EXTRA_VARS[@]}" playbooks/13_wait_site_a_hcp_prereqs.yml

say "Create Site-A tenants"
while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
  [[ "$site" == "$ENV_SITE_A_CLUSTER_NAME" ]] || continue
  vars=()
  read_tenant_extra_vars vars "$site" "$name" "$cluster_cidr" "$service_cidr" "$extra_disks" "${tenant_px_sc:-$HCP_TENANT_PX_STORAGE_CLASS}" "${guest_sc:-$HCP_GUEST_STORAGE_CLASS}"
  say "Create ${name} on Site-A"
  ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" "${COMMON_EXTRA_VARS[@]}" "${vars[@]}" "$(hcp_tenant_playbook "$site")"
done < <(hcp_tenants_for_site "$ENV_SITE_A_CLUSTER_NAME")

say "Prepare Site-B HCP prerequisites"
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" "${COMMON_EXTRA_VARS[@]}" playbooks/12_apply_site_b_hcp_policies.yml
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" "${COMMON_EXTRA_VARS[@]}" playbooks/12_fix_site_b_policy_placement.yml
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" "${COMMON_EXTRA_VARS[@]}" playbooks/13_wait_site_b_hcp_prereqs.yml

say "Create Site-B tenants"
while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
  [[ "$site" == "$ENV_SITE_B_CLUSTER_NAME" ]] || continue
  vars=()
  read_tenant_extra_vars vars "$site" "$name" "$cluster_cidr" "$service_cidr" "$extra_disks" "${tenant_px_sc:-$HCP_TENANT_PX_STORAGE_CLASS}" "${guest_sc:-$HCP_GUEST_STORAGE_CLASS}"
  say "Create ${name} on Site-B"
  ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" "${COMMON_EXTRA_VARS[@]}" "${vars[@]}" "$(hcp_tenant_playbook "$site")"
done < <(hcp_tenants_for_site "$ENV_SITE_B_CLUSTER_NAME")

say "Wait for tenant admin kubeconfig secrets"
while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
  site_kubeconfig="$(hcp_tenant_site_kubeconfig "$site" "$ROOT_DIR")"
  wait_for_admin_kubeconfig_secret "$(hcp_tenant_site_label "$site") ${name}" "$site_kubeconfig" "$HCP_NAMESPACE" "$name"
done < <(hcp_tenants)

say "Export HCP guest kubeconfigs"
HCP_KUBECONFIG_OUT_DIR="$HCP_KUBECONFIG_OUT_DIR" \
HCP_NAMESPACE="$HCP_NAMESPACE" \
./scripts/export-hcp-kubeconfigs.sh

say "Import HCP guest clusters into RHACM"
HUB_KUBECONFIG="$HUB_KUBECONFIG" \
HCP_KUBECONFIG_OUT_DIR="$HCP_KUBECONFIG_OUT_DIR" \
HCP_IMPORT_SKIP_NOT_READY="$HCP_IMPORT_SKIP_NOT_READY" \
HCP_IMPORT_WAIT="$HCP_IMPORT_WAIT" \
HCP_IMPORT_FORCE_CLEANUP="$HCP_IMPORT_FORCE_CLEANUP" \
./scripts/import-hcp-guests-to-hub.sh

say "Final RHACM import check"
./scripts/check-hcp-guest-imports.sh || true

say "HCP access summary"
while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
  site_kubeconfig="$(hcp_tenant_site_kubeconfig "$site" "$ROOT_DIR")"
  guest_kubeconfig="$(hcp_tenant_kubeconfig_path "$HCP_KUBECONFIG_OUT_DIR" "$name")"
  print_access_summary "$(hcp_tenant_site_label "$site") ${name}" "$name" "$mc" "$site_kubeconfig" "$HCP_NAMESPACE" "$guest_kubeconfig"
done < <(hcp_tenants)

cat <<MSG

Done.

Useful checks:
  oc --kubeconfig "$HUB_KUBECONFIG" get managedcluster
  oc --kubeconfig "$SITE_A_KUBECONFIG" -n "$HCP_NAMESPACE" get hostedcluster,nodepool
  oc --kubeconfig "$SITE_B_KUBECONFIG" -n "$HCP_NAMESPACE" get hostedcluster,nodepool
  ls -1 "$HCP_KUBECONFIG_OUT_DIR"/*.kubeconfig

Delete all HCP tenants with:
  ./scripts/hcp-delete.sh
MSG
