#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

HUB_CLUSTER_NAME="${HUB_CLUSTER_NAME:-lab-sno}"
HUB_API="${HUB_API:-https://api.${HUB_CLUSTER_NAME}.poc.local:6443}"
HUB_KUBECONFIG="${HUB_KUBECONFIG:-$PWD/build/${HUB_CLUSTER_NAME}/install/auth/kubeconfig}"
KUBEADMIN_PASSWORD_FILE="${KUBEADMIN_PASSWORD_FILE:-$PWD/build/${HUB_CLUSTER_NAME}/install/auth/kubeadmin-password}"

mkdir -p "$(dirname "$HUB_KUBECONFIG")"

server_for() {
  local kc="$1"
  if [ -f "$kc" ]; then
    oc --kubeconfig "$kc" whoami --show-server 2>/dev/null || true
  fi
}

current_server="$(server_for "$HUB_KUBECONFIG")"
echo "Hub kubeconfig path: $HUB_KUBECONFIG"
echo "Current server: ${current_server:-not usable}"

if [[ "$current_server" == *"api.${HUB_CLUSTER_NAME}.poc.local"* ]]; then
  echo "Hub kubeconfig already points at ${HUB_CLUSTER_NAME}."
  export KUBECONFIG="$HUB_KUBECONFIG"
  oc get managedcluster -o wide || true
  exit 0
fi

if [ -f "$HUB_KUBECONFIG" ]; then
  backup="${HUB_KUBECONFIG}.not-hub.$(date +%Y%m%d%H%M%S)"
  cp -p "$HUB_KUBECONFIG" "$backup"
  echo "Backed up non-hub kubeconfig to: $backup"
fi

# First try to find an existing kubeconfig that already points to lab-sno.
while IFS= read -r -d '' candidate; do
  candidate_server="$(server_for "$candidate")"
  if [[ "$candidate_server" == *"api.${HUB_CLUSTER_NAME}.poc.local"* ]]; then
    cp -p "$candidate" "$HUB_KUBECONFIG"
    chmod 0600 "$HUB_KUBECONFIG" || true
    echo "Recovered hub kubeconfig from: $candidate"
    export KUBECONFIG="$HUB_KUBECONFIG"
    oc get managedcluster -o wide || true
    exit 0
  fi
done < <(find "$PWD/build" "$HOME/.kube" -type f \( -name 'kubeconfig' -o -name 'kubeconfig.*' -o -name 'config' -o -name '*.kubeconfig' \) -print0 2>/dev/null || true)

# If no kubeconfig exists, recreate one with kubeadmin.
if [ ! -f "$KUBEADMIN_PASSWORD_FILE" ]; then
  echo "ERROR: Could not find a hub kubeconfig and kubeadmin password file is missing:" >&2
  echo "  $KUBEADMIN_PASSWORD_FILE" >&2
  echo "Download kubeconfig from the hub console or provide KUBEADMIN_PASSWORD_FILE, then rerun." >&2
  exit 1
fi

password="$(cat "$KUBEADMIN_PASSWORD_FILE")"
echo "Recreating hub kubeconfig by logging in to $HUB_API as kubeadmin..."
oc login "$HUB_API" \
  -u kubeadmin \
  -p "$password" \
  --kubeconfig "$HUB_KUBECONFIG" \
  --insecure-skip-tls-verify=true
chmod 0600 "$HUB_KUBECONFIG" || true

server="$(server_for "$HUB_KUBECONFIG")"
if [[ "$server" != *"api.${HUB_CLUSTER_NAME}.poc.local"* ]]; then
  echo "ERROR: repaired kubeconfig still does not point at hub. Server=$server" >&2
  exit 1
fi

export KUBECONFIG="$HUB_KUBECONFIG"
echo "Hub kubeconfig repaired."
oc get managedcluster -o wide || true
