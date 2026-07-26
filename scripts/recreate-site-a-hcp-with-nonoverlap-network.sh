#!/usr/bin/env bash
set -euo pipefail
cat >&2 <<'MSG'
This script is no longer needed.

The non-overlapping Site-A network is now the default in:
  ./scripts/hcp-create.sh

To rebuild both lab HCPs cleanly:
  ./scripts/hcp-delete.sh
  ./scripts/hcp-create.sh

To recreate in-place instead of deleting first:
  HCP_RECREATE=true ./scripts/hcp-create.sh
MSG
exit 1
