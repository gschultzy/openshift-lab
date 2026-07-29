#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
echo "This compatibility wrapper now runs the unified hub, spoke and HCP administrator workflow."
exec ./scripts/configure-lab-admin.sh "$@"
