#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/inventory-env.sh
source scripts/lib/inventory-env.sh

if [[ -f .venv/bin/activate ]]; then
  # shellcheck source=/dev/null
  source .venv/bin/activate
else
  echo "Missing .venv. Run ./scripts/bootstrap-ubuntu-24.04.sh first on the Ubuntu bastion." >&2
  exit 1
fi

INV="${INV:-$ENV_INVENTORY_FILE}"

./scripts/assert-release-baseline.sh
./scripts/sync-openshift-tools.sh

# Shared Vault and validated local sudo authentication.
# shellcheck source=scripts/lib/ansible-auth.sh
source scripts/lib/ansible-auth.sh
ansible_auth_init

run_playbook() {
  local playbook="$1"
  ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" "${BECOME_ARGS[@]}" "$playbook"
}

hub_kubeconfig_path() {
  printf '%s\n' "${HUB_KUBECONFIG:-$ENV_HUB_KUBECONFIG}"
}

hub_is_up() {
  local k
  k="$(hub_kubeconfig_path)"
  [[ -s "$k" ]] || return 1
  timeout 15 oc --kubeconfig "$k" get nodes >/dev/null 2>&1 || return 1
  timeout 15 oc --kubeconfig "$k" get clusterversion version >/dev/null 2>&1 || return 1
}

hub_install_state_exists() {
  [[ -s "$ENV_INSTALL_DIR/.openshift_install_state.json" ]] \
    && [[ -s "$ENV_INSTALL_DIR/install-config.yaml" ]] \
    && [[ -s "$ENV_INSTALL_DIR/agent-config.yaml" ]]
}

run_hub_install_if_needed() {
  if truthy "${FORCE_REBUILD_HUB:-false}"; then
    echo "FORCE_REBUILD_HUB=true set. Running hub install steps."
    run_playbook playbooks/01_render_agent_iso.yml
    run_playbook playbooks/02_create_vsphere_vm.yml
    run_playbook playbooks/03_wait_install.yml
  elif hub_is_up; then
    echo "Hub SNO is already reachable and running. Skipping ISO render, VM create/update, and install wait."
    echo "Kubeconfig: $(hub_kubeconfig_path)"
  elif hub_install_state_exists; then
    echo "Existing Agent installation state detected. Resuming the current SNO installation without regenerating the ISO."
    run_playbook playbooks/03_wait_install.yml
  else
    echo "Hub SNO is not reachable and no reusable Agent installation state exists. Running hub install steps."
    run_playbook playbooks/01_render_agent_iso.yml
    run_playbook playbooks/02_create_vsphere_vm.yml
    run_playbook playbooks/03_wait_install.yml
  fi
}

require_hub_up() {
  if hub_is_up; then
    echo "Hub SNO is reachable. Continuing day-2 flow."
    export KUBECONFIG="$(hub_kubeconfig_path)"
  else
    echo "Hub SNO is not reachable using $(hub_kubeconfig_path)." >&2
    echo "Run ./scripts/run.sh first, or set HUB_KUBECONFIG to a valid hub kubeconfig." >&2
    exit 1
  fi
}


run_playbook playbooks/00_preflight.yml
# Prepare authoritative and bastion-side DNS before any SNO install activity.
configure_local_become_auth
run_playbook playbooks/04_configure_ad_dns.yml
run_hub_install_if_needed

run_playbook playbooks/02_add_sno_extra_disk.yml
run_playbook playbooks/05_install_lvm_storage.yml
run_playbook playbooks/06_install_acm.yml
# ACM creates MCE asynchronously after MultiClusterHub is applied. The repair script waits
# for the MCE CRD and object before applying HCP topology settings.
# Keep HCP globally enabled but do not host tenant control planes on the SNO hub.
KUBECONFIG="$(hub_kubeconfig_path)" ./scripts/fix-acm-hypershift-local-hosting.sh
KUBECONFIG="$(hub_kubeconfig_path)" ./scripts/wait-acm-ready.sh
run_playbook playbooks/07_configure_assisted_service.yml
run_playbook playbooks/07_enable_baremetal_provisioning.yml
# Site-A
run_playbook playbooks/10_configure_bm_ad_dns.yml
run_playbook playbooks/05_discover_idrac_nics.yml
run_playbook playbooks/05_idrac_preflight.yml
run_playbook playbooks/08_apply_baremetal_cluster.yml
run_playbook playbooks/09_wait_baremetal_cluster.yml

# Site-A ACM Governance / HCP hosting policies
run_playbook playbooks/12_apply_site_a_hcp_policies.yml
run_playbook playbooks/12_fix_site_a_policy_placement.yml

# Site-B
run_playbook playbooks/10_configure_site_b_ad_dns.yml
# Auto-fill Site-B boot_mac placeholders from iDRAC before preflight.
run_playbook playbooks/05_discover_site_b_idrac_nics.yml
run_playbook playbooks/05_idrac_preflight_site_b.yml
run_playbook playbooks/08_apply_site_b_baremetal_cluster.yml
run_playbook playbooks/09_wait_site_b_baremetal_cluster.yml

# Site-B ACM Governance / HCP hosting policies
run_playbook playbooks/12_apply_site_b_hcp_policies.yml
run_playbook playbooks/12_fix_site_b_policy_placement.yml
