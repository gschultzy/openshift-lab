#!/usr/bin/env bash
set -euo pipefail
cat >&2 <<'MSG'
This repo now uses one HCP create flow only.

Run:
  ./scripts/hcp-create.sh

That creates/imports all four tenants:
  site-a-hcp-t1-px
  site-a-hcp-t2-kv
  site-b-hcp-t1-px
  site-b-hcp-t2-kv
MSG
exit 1
