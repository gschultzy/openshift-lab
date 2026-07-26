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

if ! ansible-galaxy collection list purestorage.flasharray >/dev/null 2>&1; then
  echo "purestorage.flasharray collection is missing; installing requirements.yml" >&2
  ansible-galaxy collection install -r requirements.yml
fi

python - <<'PYDEPS'
try:
    import purestorage  # noqa: F401
except Exception as exc:
    raise SystemExit(
        "Missing Python dependency 'purestorage'. Run: source .venv/bin/activate && python -m pip install -r requirements-python.txt"
    ) from exc
try:
    import pypureclient  # noqa: F401
except Exception:
    # Some purestorage modules only need this for API 2.x operations, but keep the message helpful.
    pass
PYDEPS

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

# The purefa_token module only returns the API token when it creates/rotates it.
# Default to recreate=true so this script is deterministic for automation.
PURE_TOKEN_RECREATE="${PURE_TOKEN_RECREATE:-true}"

ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/22_create_pure_flasharray_api_token.yml \
  -e "pure_flasharray_token_recreate=${PURE_TOKEN_RECREATE}"
