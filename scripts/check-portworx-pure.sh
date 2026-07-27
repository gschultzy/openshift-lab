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

PORTWORX_SITE_ARGS=()
if [[ -n "${SITE:-}" ]]; then
  case "$SITE" in
    site-a|site-b) PORTWORX_SITE_ARGS=(-e "portworx_pure_site_filter=$SITE") ;;
    *) echo "Invalid SITE=$SITE. Use SITE=site-a, SITE=site-b, or leave SITE unset for both." >&2; exit 2 ;;
  esac
fi

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

# Protect against the common failure where the hub kubeconfig derived from main.yml
# has accidentally been overwritten with a Site-A/Site-B kubeconfig.
./scripts/ensure-hub-kubeconfig.sh

export KUBECONFIG="$(hub_kubeconfig_path)"

ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/17_validate_hub_context.yml

ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/21_check_portworx_pure_status.yml "${PORTWORX_SITE_ARGS[@]}"
