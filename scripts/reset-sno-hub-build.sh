#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source .venv/bin/activate 2>/dev/null || true
rm -rf build/lab-sno
echo "Removed build/lab-sno. Next run:"
echo "  ansible-playbook -i inventories/env/hosts.yml playbooks/01_render_agent_iso.yml --ask-vault-pass"
echo "  ansible-playbook -i inventories/env/hosts.yml playbooks/02_create_vsphere_vm.yml --ask-vault-pass"
