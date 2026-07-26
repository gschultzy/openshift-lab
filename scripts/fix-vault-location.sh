#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GROUP_VARS_DIR="$ROOT_DIR/inventories/env/group_vars"
ALL_DIR="$GROUP_VARS_DIR/all"
OLD_MAIN="$GROUP_VARS_DIR/all.yml"
NEW_MAIN="$ALL_DIR/main.yml"
OLD_VAULT="$GROUP_VARS_DIR/vault.yml"
NEW_VAULT="$ALL_DIR/vault.yml"
EXAMPLE="$ALL_DIR/vault.yml.example"

mkdir -p "$ALL_DIR"

if [[ -f "$OLD_MAIN" && ! -f "$NEW_MAIN" ]]; then
  mv "$OLD_MAIN" "$NEW_MAIN"
  echo "Moved non-secret vars to: $NEW_MAIN"
elif [[ -f "$NEW_MAIN" ]]; then
  echo "Non-secret vars already exist at: $NEW_MAIN"
else
  echo "WARNING: Could not find non-secret vars at either:"
  echo "  $OLD_MAIN"
  echo "  $NEW_MAIN"
fi

if [[ -f "$NEW_VAULT" ]]; then
  echo "Vault already exists at: $NEW_VAULT"
elif [[ -f "$OLD_VAULT" ]]; then
  mv "$OLD_VAULT" "$NEW_VAULT"
  echo "Moved vault file to: $NEW_VAULT"
elif [[ -f "$EXAMPLE" ]]; then
  cp "$EXAMPLE" "$NEW_VAULT"
  echo "Created vault file from example: $NEW_VAULT"
  echo "Now edit/encrypt it:"
  echo "  ansible-vault encrypt $NEW_VAULT"
  echo "  ansible-vault edit $NEW_VAULT"
else
  echo "WARNING: Could not find old vault or example file. Expected one of:"
  echo "  $OLD_VAULT"
  echo "  $EXAMPLE"
fi

echo
echo "Validate Ansible can see both normal vars and vault vars:"
echo "  ansible-inventory -i inventories/env/hosts.yml --list --ask-vault-pass"
echo "  ansible-inventory -i inventories/env/hosts.yml --list --ask-vault-pass | jq '._meta.hostvars.localhost | {cluster_name, has_vcenter_password: has(\"vault_vcenter_password\")}'"
