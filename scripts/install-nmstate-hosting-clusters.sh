#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/inventory-env.sh
source scripts/lib/inventory-env.sh

if [[ -f .venv/bin/activate ]]; then
  # shellcheck source=/dev/null
  source .venv/bin/activate
else
  echo "Missing .venv. Run ./scripts/bootstrap-ubuntu-24.04.sh first." >&2
  exit 1
fi

INV="${INV:-$ENV_INVENTORY_FILE}"

./scripts/assert-release-baseline.sh
./scripts/sync-openshift-tools.sh

# shellcheck source=scripts/lib/ansible-auth.sh
source scripts/lib/ansible-auth.sh
ansible_auth_init

run_playbook() {
  ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" "${BECOME_ARGS[@]}" "$1"
}

echo "### Reconcile Kubernetes NMState on Site-A"
run_playbook playbooks/12_apply_site_a_hcp_policies.yml

echo
echo "### Reconcile Kubernetes NMState on Site-B"
run_playbook playbooks/12_apply_site_b_hcp_policies.yml

echo
echo "### Wait for Kubernetes NMState on Site-A and Site-B"
run_playbook playbooks/08_wait_nmstate_on_hosting_clusters.yml
