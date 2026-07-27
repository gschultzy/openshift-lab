#!/usr/bin/env bash
# Shared Ansible Vault and local sudo authentication helpers.
# Source this file from a runner, then call ansible_auth_init.

VAULT_PASSWORD_FILE_TMP=""
BECOME_PASSWORD_FILE_TMP=""
VAULT_ARGS=()
BECOME_ARGS=()
LOCAL_BECOME_AUTH_READY=false

truthy() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup_ansible_auth_files() {
  [[ -z "${VAULT_PASSWORD_FILE_TMP:-}" ]] || rm -f "$VAULT_PASSWORD_FILE_TMP"
  [[ -z "${BECOME_PASSWORD_FILE_TMP:-}" ]] || rm -f "$BECOME_PASSWORD_FILE_TMP"
}

ansible_auth_init() {
  trap cleanup_ansible_auth_files EXIT

  if [[ -n "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ]]; then
    if [[ ! -r "$ANSIBLE_VAULT_PASSWORD_FILE" ]]; then
      echo "ANSIBLE_VAULT_PASSWORD_FILE is not readable: $ANSIBLE_VAULT_PASSWORD_FILE" >&2
      return 1
    fi
    VAULT_ARGS=(--vault-password-file "$ANSIBLE_VAULT_PASSWORD_FILE")
    return 0
  fi

  VAULT_PASSWORD_FILE_TMP="$(mktemp)"
  chmod 600 "$VAULT_PASSWORD_FILE_TMP"

  local vault_password
  read -r -s -p "Vault password: " vault_password
  echo
  printf '%s\n' "$vault_password" > "$VAULT_PASSWORD_FILE_TMP"
  unset vault_password

  VAULT_ARGS=(--vault-password-file "$VAULT_PASSWORD_FILE_TMP")
}

validate_local_sudo_password_value() {
  local password="$1"

  # Always validate a fresh credential instead of accidentally relying on a
  # previously cached sudo timestamp.
  sudo -k >/dev/null 2>&1 || true
  if printf '%s\n' "$password" | sudo -S -p '' -v >/dev/null 2>&1; then
    sudo -k >/dev/null 2>&1 || true
    return 0
  fi

  sudo -k >/dev/null 2>&1 || true
  return 1
}

validate_local_sudo_password_file() {
  local password_file="$1"

  [[ -r "$password_file" ]] || return 1

  sudo -k >/dev/null 2>&1 || true
  if sudo -S -p '' -v < "$password_file" >/dev/null 2>&1; then
    sudo -k >/dev/null 2>&1 || true
    return 0
  fi

  sudo -k >/dev/null 2>&1 || true
  return 1
}

configure_local_become_auth() {
  if truthy "$LOCAL_BECOME_AUTH_READY"; then
    return 0
  fi

  # Passwordless sudo, or a still-valid cached credential, requires no password
  # file for Ansible's local become tasks.
  if sudo -n true >/dev/null 2>&1; then
    echo "Local sudo access is already available for Ubuntu DNS resolver configuration."
    LOCAL_BECOME_AUTH_READY=true
    return 0
  fi

  if [[ -n "${ANSIBLE_BECOME_PASSWORD_FILE:-}" ]]; then
    if [[ ! -r "$ANSIBLE_BECOME_PASSWORD_FILE" ]]; then
      echo "ANSIBLE_BECOME_PASSWORD_FILE is not readable: $ANSIBLE_BECOME_PASSWORD_FILE" >&2
      return 1
    fi
    if ! validate_local_sudo_password_file "$ANSIBLE_BECOME_PASSWORD_FILE"; then
      echo "The password in ANSIBLE_BECOME_PASSWORD_FILE was rejected by sudo." >&2
      echo "Update that file with the Ubuntu login/sudo password for user $(id -un)." >&2
      return 1
    fi

    BECOME_ARGS=(--become-password-file "$ANSIBLE_BECOME_PASSWORD_FILE")
    LOCAL_BECOME_AUTH_READY=true
    echo "Local sudo credentials from ANSIBLE_BECOME_PASSWORD_FILE were validated."
    return 0
  fi

  BECOME_PASSWORD_FILE_TMP="$(mktemp)"
  chmod 600 "$BECOME_PASSWORD_FILE_TMP"

  local max_attempts="${LOCAL_SUDO_PASSWORD_ATTEMPTS:-3}"
  local attempt=1
  local become_password

  echo "Ubuntu DNS resolver configuration requires local sudo access."
  echo "Enter the Ubuntu login/sudo password for user $(id -un), not the Ansible Vault password."

  while (( attempt <= max_attempts )); do
    read -r -s -p "Local sudo password: " become_password
    echo

    if validate_local_sudo_password_value "$become_password"; then
      printf '%s\n' "$become_password" > "$BECOME_PASSWORD_FILE_TMP"
      unset become_password
      BECOME_ARGS=(--become-password-file "$BECOME_PASSWORD_FILE_TMP")
      LOCAL_BECOME_AUTH_READY=true
      echo "Local sudo credentials validated."
      return 0
    fi

    unset become_password
    if (( attempt < max_attempts )); then
      echo "That password was rejected by sudo. Please try again ($((attempt + 1))/$max_attempts)." >&2
    fi
    ((attempt += 1))
  done

  echo "Unable to validate local sudo credentials after $max_attempts attempts." >&2
  echo "Confirm the Ubuntu login password with: sudo -k && sudo -v" >&2
  return 1
}
