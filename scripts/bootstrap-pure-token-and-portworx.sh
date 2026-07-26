#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -n "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ]]; then
  ./scripts/create-pure-api-token.sh
  ./scripts/run-portworx-pure-node-prep.sh
  ./scripts/run-portworx-pure-install.sh
else
  VAULT_PASSWORD_FILE_TMP="$(mktemp)"
  chmod 600 "$VAULT_PASSWORD_FILE_TMP"
  trap 'rm -f "$VAULT_PASSWORD_FILE_TMP"' EXIT

  read -r -s -p "Vault password: " VAULT_PASSWORD
  echo
  printf '%s\n' "$VAULT_PASSWORD" > "$VAULT_PASSWORD_FILE_TMP"
  unset VAULT_PASSWORD

  export ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PASSWORD_FILE_TMP"
  ./scripts/create-pure-api-token.sh
  ./scripts/run-portworx-pure-node-prep.sh
  ./scripts/run-portworx-pure-install.sh
fi
