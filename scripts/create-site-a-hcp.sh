#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/hcp-tenants.sh
source scripts/lib/hcp-tenants.sh

cat >&2 <<'MSG'
This repo uses one HCP create flow only.

Run:
  ./scripts/hcp-create.sh

Configured tenants are read from hcp_tenants in:
  inventories/env/group_vars/all/main.yml
MSG

echo >&2
echo "Configured tenants:" >&2
hcp_tenants | awk -F'|' '{printf "  %s (%s)\n", $2, $1}' >&2
exit 1
