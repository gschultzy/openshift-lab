#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/inventory-env.sh
source scripts/lib/inventory-env.sh

if [[ -f .venv/bin/activate ]]; then
  # shellcheck source=/dev/null
  source .venv/bin/activate
fi

export HUB_KUBECONFIG="${HUB_KUBECONFIG:-$ENV_HUB_KUBECONFIG}"
export KUBECONFIG="$HUB_KUBECONFIG"
# Repair/restore the hub kubeconfig first if it was accidentally overwritten by a spoke kubeconfig.
"$PWD/scripts/repair-hub-kubeconfig.sh"
export HUB_KUBECONFIG="${HUB_KUBECONFIG:-$ENV_HUB_KUBECONFIG}"
export KUBECONFIG="$HUB_KUBECONFIG"

if [[ ! -s "$KUBECONFIG" ]]; then
  echo "Hub kubeconfig not found: $KUBECONFIG" >&2
  exit 1
fi

echo "Using kubeconfig: $KUBECONFIG"
echo "API server: $(oc --kubeconfig "$KUBECONFIG" whoami --show-server)"
echo
oc --kubeconfig "$KUBECONFIG" get managedcluster -o wide || true

echo
if ! oc --kubeconfig "$KUBECONFIG" whoami --show-server | grep -Fq "$ENV_HUB_API_HOST"; then
  echo "ERROR: this kubeconfig does not point at the configured hub. Do not continue." >&2
  exit 1
fi

if ! oc --kubeconfig "$KUBECONFIG" get managedcluster site-a >/dev/null 2>&1; then
  echo "ERROR: managedcluster/site-a is missing on the hub." >&2
  echo "Run playbooks/08_apply_baremetal_cluster.yml from the hub context first." >&2
  exit 1
fi

if ! oc --kubeconfig "$KUBECONFIG" get managedcluster site-b >/dev/null 2>&1; then
  echo "ERROR: managedcluster/site-b is missing on the hub." >&2
  echo "Run playbooks/08_apply_site_b_baremetal_cluster.yml from the hub context first." >&2
  exit 1
fi

./scripts/run-acm-mce-integration.sh
./scripts/run-site-a-policies.sh
./scripts/run-site-b-policies.sh
