#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .venv/bin/activate ]]; then
  # shellcheck source=/dev/null
  source .venv/bin/activate
else
  echo "Missing .venv. Run ./scripts/bootstrap-ubuntu-24.04.sh first." >&2
  exit 1
fi

# shellcheck source=scripts/lib/inventory-env.sh
source scripts/lib/inventory-env.sh
# shellcheck source=scripts/lib/ansible-auth.sh
source scripts/lib/ansible-auth.sh
# shellcheck source=scripts/lib/hcp-tenants.sh
source scripts/lib/hcp-tenants.sh

INV="${INV:-$ENV_INVENTORY_FILE}"
ansible_auth_init

ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/07_configure_lab_admin.yml

# Configure any HostedClusters that already exist.
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/29_configure_hcp_lab_admin.yml

# Grant guest RBAC for every exported kubeconfig and defer tenants that are not ready yet.
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/30_grant_hcp_lab_admin.yml \
  -e lab_admin_hcp_skip_missing_kubeconfigs=true

cat <<'MSG'

Shared lab administrator reconciliation completed.
Username: admin
Password: stored in Ansible Vault or the Pod 74 lab default
MSG
