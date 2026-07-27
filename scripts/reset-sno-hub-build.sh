#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/inventory-env.sh
source scripts/lib/inventory-env.sh
source .venv/bin/activate 2>/dev/null || true
rm -rf "$ENV_BUILD_ROOT"
echo "Removed $ENV_BUILD_ROOT. Next run:"
echo "  ansible-playbook -i inventories/env/hosts.yml playbooks/01_render_agent_iso.yml --ask-vault-pass"
echo "  ansible-playbook -i inventories/env/hosts.yml playbooks/02_create_vsphere_vm.yml --ask-vault-pass"
