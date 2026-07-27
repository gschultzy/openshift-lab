#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/inventory-env.sh
source scripts/lib/inventory-env.sh
export KUBECONFIG="${KUBECONFIG:-$ENV_HUB_KUBECONFIG}"
./scripts/acm-diagnostics.sh
