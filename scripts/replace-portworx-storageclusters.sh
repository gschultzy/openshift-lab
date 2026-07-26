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

./scripts/ensure-hub-kubeconfig.sh
export KUBECONFIG="${HUB_KUBECONFIG:-$PWD/build/hub-sno/install/auth/kubeconfig}"

ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/17_validate_hub_context.yml

# Re-render and re-apply the Pure secret + replacement KDS StorageCluster policy
# without touching node-prep or reinstalling the operator. The same CR name is used,
# so this overwrites the StorageCluster definition on Site-A/Site-B when the policy is enforced.
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/20_apply_portworx_pure_policies.yml \
  -e portworx_pure_apply_node_prep=false \
  -e portworx_pure_apply_operator=false \
  -e portworx_pure_apply_storagecluster=true \
  -e portworx_enable_openshift_console_plugin=false \
  -e portworx_pure_apply_hcp_storageclasses=true

ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/21_check_portworx_pure_status.yml
