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

if [[ "${CONFIRM_PORTWORX_WIPE:-false}" != "true" ]]; then
  cat >&2 <<'MSG'
Refusing to wipe Portworx without explicit confirmation.

This is destructive. It uses StorageCluster deleteStrategy.type=UninstallAndWipe
with ignoreVolumes=true on Site-A and Site-B.

Recommended clean sequence:
  ./scripts/hcp-delete.sh
  CONFIRM_PORTWORX_WIPE=true ./scripts/portworx-uninstall-and-wipe-spokes.sh
  ./scripts/run-portworx-pure-install.sh
  ./scripts/hcp-create.sh
MSG
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
  printf '%s\n' "$VAULT_PASSWORD" > "$VAULT_PASSWORD_FILE_TMP"
  unset VAULT_PASSWORD

  VAULT_ARGS=(--vault-password-file "$VAULT_PASSWORD_FILE_TMP")
fi

./scripts/ensure-hub-kubeconfig.sh
export HUB_KUBECONFIG="${HUB_KUBECONFIG:-$PWD/build/lab-sno/install/auth/kubeconfig}"
export KUBECONFIG="$HUB_KUBECONFIG"

ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/17_validate_hub_context.yml
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/28_portworx_uninstall_and_wipe_spokes.yml
