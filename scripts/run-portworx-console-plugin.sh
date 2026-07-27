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

hub_kubeconfig_path() {
  printf '%s\n' "${HUB_KUBECONFIG:-$ENV_HUB_KUBECONFIG}"
}

./scripts/ensure-hub-kubeconfig.sh
export KUBECONFIG="$(hub_kubeconfig_path)"

ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/17_validate_hub_context.yml

# Re-apply the operator policy idempotently and enable the OpenShift console plugin
# on every Portworx/Pure placement target. This does not re-run node prep or recreate
# the StorageCluster.
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/20_apply_portworx_pure_policies.yml \
  -e portworx_pure_apply_node_prep=false \
  -e portworx_pure_apply_operator=true \
  -e portworx_pure_apply_storagecluster=false \
  -e portworx_enable_openshift_console_plugin=true

# The RHACM policy declares the desired state. This direct idempotent patch is a
# safety net that preserves existing OpenShift console plugins and appends
# "portworx" if the policy has not reconciled yet.
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/25_enable_portworx_console_plugin_direct.yml

ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/21_check_portworx_pure_status.yml
