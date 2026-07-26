#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .venv/bin/activate ]]; then
  # shellcheck source=/dev/null
  source .venv/bin/activate
fi

export HUB_KUBECONFIG="${HUB_KUBECONFIG:-$PWD/build/lab-sno/install/auth/kubeconfig}"
export KUBECONFIG="$HUB_KUBECONFIG"
# Repair/restore the hub kubeconfig first if it was accidentally overwritten by a spoke kubeconfig.
"$PWD/scripts/repair-hub-kubeconfig.sh"
export HUB_KUBECONFIG="${HUB_KUBECONFIG:-$PWD/build/lab-sno/install/auth/kubeconfig}"
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
if ! oc --kubeconfig "$KUBECONFIG" whoami --show-server | grep -q 'api.lab-sno.poc.local'; then
  echo "ERROR: this kubeconfig does not point at lab-sno. Do not continue." >&2
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
