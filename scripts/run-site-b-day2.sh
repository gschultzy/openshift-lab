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

INV="inventories/pod22/hosts.yml"

# Ask for the Ansible Vault password once, then reuse it for every playbook.
# If ANSIBLE_VAULT_PASSWORD_FILE is already set, use that instead and do not prompt.
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

run_playbook() {
  local playbook="$1"
  ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" "$playbook"
}

truthy() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

hub_kubeconfig_path() {
  printf '%s\n' "${HUB_KUBECONFIG:-$PWD/build/hub-sno/install/auth/kubeconfig}"
}

hub_is_up() {
  local k
  k="$(hub_kubeconfig_path)"
  [[ -s "$k" ]] || return 1
  timeout 15 oc --kubeconfig "$k" get nodes >/dev/null 2>&1 || return 1
  timeout 15 oc --kubeconfig "$k" get clusterversion version >/dev/null 2>&1 || return 1
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
  else
    echo "Hub SNO is not reachable yet. Running hub install steps."
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


require_hub_up
run_playbook playbooks/10_configure_site_b_ad_dns.yml
# This discovery step now auto-fills CHANGE_ME_* boot_mac placeholders for Site-B
# using Integrated NIC 1 Port 1 when it is link-up at 25Gbps.
run_playbook playbooks/05_discover_site_b_idrac_nics.yml
run_playbook playbooks/05_idrac_preflight_site_b.yml
run_playbook playbooks/08_apply_site_b_baremetal_cluster.yml
run_playbook playbooks/08_reboot_site_b_nodes.yml
run_playbook playbooks/09_wait_site_b_baremetal_cluster.yml

# Site-B ACM Governance / HCP hosting policies
run_playbook playbooks/12_apply_site_b_hcp_policies.yml
run_playbook playbooks/12_fix_site_b_policy_placement.yml
