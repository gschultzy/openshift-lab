#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

HUB_CLUSTER_NAME="${HUB_CLUSTER_NAME:-hub-sno}"
HUB_KUBECONFIG="${HUB_KUBECONFIG:-$PWD/build/${HUB_CLUSTER_NAME}/install/auth/kubeconfig}"
EXPECTED_API_HOST="api.${HUB_CLUSTER_NAME}.poc.local"

server_for() {
  local kc="$1"
  if [[ -s "$kc" ]]; then
    oc --kubeconfig "$kc" whoami --show-server 2>/dev/null || true
  fi
}

server="$(server_for "$HUB_KUBECONFIG")"
echo "Hub kubeconfig path: $HUB_KUBECONFIG"
echo "Detected API server: ${server:-not usable}"

if [[ "$server" != *"$EXPECTED_API_HOST"* ]]; then
  echo "Hub kubeconfig is missing or points at the wrong API. Attempting repair..." >&2
  HUB_CLUSTER_NAME="$HUB_CLUSTER_NAME" HUB_KUBECONFIG="$HUB_KUBECONFIG" ./scripts/repair-hub-kubeconfig.sh
fi

server="$(server_for "$HUB_KUBECONFIG")"
if [[ "$server" != *"$EXPECTED_API_HOST"* ]]; then
  echo "ERROR: kubeconfig still does not point at the RHACM hub after repair." >&2
  echo "Current API server: ${server:-not usable}" >&2
  echo "Expected API host: $EXPECTED_API_HOST" >&2
  exit 1
fi

if ! timeout 20 oc --kubeconfig "$HUB_KUBECONFIG" get managedcluster site-a >/dev/null 2>&1; then
  echo "ERROR: kubeconfig points at hub API but managedcluster/site-a is not visible." >&2
  echo "This does not look like the RHACM hub inventory." >&2
  exit 1
fi

if ! timeout 20 oc --kubeconfig "$HUB_KUBECONFIG" get managedcluster site-b >/dev/null 2>&1; then
  echo "ERROR: kubeconfig points at hub API but managedcluster/site-b is not visible." >&2
  echo "This does not look like the RHACM hub inventory." >&2
  exit 1
fi

echo "Hub kubeconfig OK: $server"
