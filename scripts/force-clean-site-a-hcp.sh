#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec ./scripts/force-clean-site-a-hcp-test.sh "$@"
