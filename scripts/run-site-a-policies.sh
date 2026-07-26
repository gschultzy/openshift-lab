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

INV="inventories/env/hosts.yml"

if [[ -n "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ]]; then
  VAULT_ARGS=(--vault-password-file "$ANSIBLE_VAULT_PASSWORD_FILE")
else
  VAULT_PASSWORD_FILE_TMP="$(mktemp)"
  chmod 600 "$VAULT_PASSWORD_FILE_TMP"
  trap 'rm -f "$VAULT_PASSWORD_FILE_TMP"' EXIT

  read -r -s -p "Vault password: " VAULT_PASSWORD
  echo
  printf '%s
' "$VAULT_PASSWORD" > "$VAULT_PASSWORD_FILE_TMP"
  unset VAULT_PASSWORD

  VAULT_ARGS=(--vault-password-file "$VAULT_PASSWORD_FILE_TMP")
fi

hub_kubeconfig_path() {
  printf '%s
' "${HUB_KUBECONFIG:-$PWD/build/lab-sno/install/auth/kubeconfig}"
}

hub_is_up() {
  local k
  k="$(hub_kubeconfig_path)"
  [[ -s "$k" ]] || return 1
  timeout 15 oc --kubeconfig "$k" get nodes >/dev/null 2>&1 || return 1
  timeout 15 oc --kubeconfig "$k" get clusterversion version >/dev/null 2>&1 || return 1
}

if ! hub_is_up; then
  echo "Hub SNO is not reachable using $(hub_kubeconfig_path)." >&2
  echo "Set HUB_KUBECONFIG or run ./scripts/run.sh first." >&2
  exit 1
fi

export KUBECONFIG="$(hub_kubeconfig_path)"

ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/17_validate_hub_context.yml

ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/18_check_spoke_mce_conflicts.yml
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/17_configure_acm_mce_integration.yml

ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/12_apply_site_a_hcp_policies.yml
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/12_fix_site_a_policy_placement.yml

oc -n site-a-policies get managedclustersetbinding,placement,placementdecision,policy,placementbinding
