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

if [[ "${CONFIRM_DELETE_HUB:-false}" != "true" ]]; then
  cat >&2 <<MSG
Refusing to delete the hub without confirmation.

This deletes the vSphere VM named by sno_vm_name and removes the configured build_root.
It does not clean Site-A/Site-B bare-metal hosts or Pure volumes.

Run again with:
  CONFIRM_DELETE_HUB=true ./scripts/hub-delete.sh
MSG
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

ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/04_delete_sno_hub_vm.yml \
  -e confirm_delete_hub=true

rm -rf "$ENV_BUILD_ROOT"

echo
cat <<MSG
Hub delete requested.

To recreate:
  ./scripts/run.sh
MSG
