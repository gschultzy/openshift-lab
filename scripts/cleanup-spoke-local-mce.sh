#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

INV="${INV:-inventories/env/hosts.yml}"
HUB_KUBECONFIG="${HUB_KUBECONFIG:-${KUBECONFIG:-$ROOT_DIR/build/lab-sno/install/auth/kubeconfig}}"
export HUB_KUBECONFIG
export KUBECONFIG="$HUB_KUBECONFIG"

if [[ ! -f "$HUB_KUBECONFIG" ]]; then
  echo "ERROR: hub kubeconfig not found: $HUB_KUBECONFIG" >&2
  exit 1
fi

server="$(oc --kubeconfig "$HUB_KUBECONFIG" whoami --show-server 2>/dev/null || true)"
echo "Using hub kubeconfig: $HUB_KUBECONFIG"
echo "Hub API server: $server"

if [[ "$server" != *"api.lab-sno."* && "$server" != *"lab-sno"* ]]; then
  echo "ERROR: this kubeconfig does not point at lab-sno. Do not continue." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required on the bastion." >&2
  exit 1
fi

if [[ "${CONFIRM_REMOVE_LOCAL_MCE:-}" != "true" ]]; then
  cat >&2 <<MSG
ERROR: confirmation required.

This removes stale local ACM/MCE hub components from Site-A and Site-B.
It preserves the RHACM agent namespaces used by the real hub.

Run it like this:

  CONFIRM_REMOVE_LOCAL_MCE=true ./scripts/cleanup-spoke-local-mce.sh
MSG
  exit 1
fi

if [[ -t 0 ]]; then
  read -r -s -p "Vault password: " VAULT_PASS
  echo
  VAULT_FILE="$(mktemp)"
  trap 'rm -f "$VAULT_FILE"' EXIT
  printf '%s' "$VAULT_PASS" > "$VAULT_FILE"
  chmod 600 "$VAULT_FILE"
  VAULT_ARGS=(--vault-password-file "$VAULT_FILE")
else
  VAULT_ARGS=(--ask-vault-pass)
fi

ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/19_cleanup_spoke_local_mce.yml
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/18_check_spoke_mce_conflicts.yml
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/17_configure_acm_mce_integration.yml
