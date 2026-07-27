#!/usr/bin/env bash
set -euo pipefail

# Synchronize repo-local OpenShift client tools with ocp_release_version from
# inventories/env/group_vars/all/main.yml. The tools are installed into
# .venv/bin by default, so no sudo access is required and this repository does
# not depend on stale system-wide binaries.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ ! -x .venv/bin/python3 ]]; then
  echo "Missing .venv. Run ./scripts/bootstrap-ubuntu-24.04.sh first." >&2
  exit 1
fi

# shellcheck source=/dev/null
source .venv/bin/activate
# shellcheck source=scripts/lib/inventory-env.sh
source scripts/lib/inventory-env.sh

OPENSHIFT_VERSION="${OPENSHIFT_VERSION:-$(inventory_value ocp_release_version)}"
INSTALL_BIN_DIR="${INSTALL_BIN_DIR:-$REPO_ROOT/.venv/bin}"

if [[ ! "$OPENSHIFT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "OPENSHIFT_VERSION must be an exact x.y.z release; received: $OPENSHIFT_VERSION" >&2
  echo "The default is read from ocp_release_version in main.yml." >&2
  exit 1
fi
MIRROR_BASE="${OPENSHIFT_CLIENT_MIRROR:-https://mirror.openshift.com/pub/openshift-v4/clients/ocp}"
FORCE_SYNC="${FORCE_SYNC_OPENSHIFT_TOOLS:-false}"

version_from_output() {
  grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

installed_version() {
  local binary="$1"
  local path="$INSTALL_BIN_DIR/$binary"

  [[ -x "$path" ]] || return 0

  case "$binary" in
    oc|kubectl)
      "$path" version --client 2>/dev/null | version_from_output
      ;;
    openshift-install)
      "$path" version 2>/dev/null | version_from_output
      ;;
  esac
}

needs_sync=false
for binary in oc openshift-install; do
  current="$(installed_version "$binary")"
  if [[ "$FORCE_SYNC" == "true" || "$current" != "$OPENSHIFT_VERSION" ]]; then
    needs_sync=true
    if [[ -n "$current" ]]; then
      echo "$binary is $current; inventory requires $OPENSHIFT_VERSION."
    else
      echo "$binary is missing from $INSTALL_BIN_DIR; inventory requires $OPENSHIFT_VERSION."
    fi
  fi
done

# kubectl reports its Kubernetes version rather than the OpenShift release
# version, so only require the repo-local binary to exist. It is refreshed from
# the same OpenShift client archive whenever oc or openshift-install is synced.
if [[ ! -x "$INSTALL_BIN_DIR/kubectl" ]]; then
  needs_sync=true
  echo "kubectl is missing from $INSTALL_BIN_DIR."
fi

if [[ "$needs_sync" != "true" ]]; then
  echo "OpenShift client tools already match $OPENSHIFT_VERSION in $INSTALL_BIN_DIR."
  exit 0
fi

for command_name in curl tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is missing: $command_name" >&2
    exit 1
  fi
done

mkdir -p "$INSTALL_BIN_DIR"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

client_url="$MIRROR_BASE/$OPENSHIFT_VERSION/openshift-client-linux.tar.gz"
installer_url="$MIRROR_BASE/$OPENSHIFT_VERSION/openshift-install-linux.tar.gz"

echo "Downloading OpenShift $OPENSHIFT_VERSION client tools..."
if ! curl --fail --location --silent --show-error \
  --retry 3 --retry-delay 2 \
  "$client_url" -o "$tmpdir/openshift-client-linux.tar.gz"; then
  echo "Unable to download $client_url" >&2
  echo "Confirm outbound HTTPS access or set OPENSHIFT_CLIENT_MIRROR." >&2
  exit 1
fi

tar -xzf "$tmpdir/openshift-client-linux.tar.gz" -C "$tmpdir" oc kubectl

if ! curl --fail --location --silent --show-error \
  --retry 3 --retry-delay 2 \
  "$installer_url" -o "$tmpdir/openshift-install-linux.tar.gz"; then
  echo "Unable to download $installer_url" >&2
  echo "Confirm outbound HTTPS access or set OPENSHIFT_CLIENT_MIRROR." >&2
  exit 1
fi

tar -xzf "$tmpdir/openshift-install-linux.tar.gz" -C "$tmpdir" openshift-install

install -m 0755 "$tmpdir/oc" "$INSTALL_BIN_DIR/oc"
install -m 0755 "$tmpdir/kubectl" "$INSTALL_BIN_DIR/kubectl"
install -m 0755 "$tmpdir/openshift-install" "$INSTALL_BIN_DIR/openshift-install"

oc_version="$(installed_version oc)"
kubectl_version="$("$INSTALL_BIN_DIR/kubectl" version --client 2>/dev/null | head -n1 || true)"
installer_version="$(installed_version openshift-install)"

if [[ "$oc_version" != "$OPENSHIFT_VERSION" || \
      "$installer_version" != "$OPENSHIFT_VERSION" || \
      ! -x "$INSTALL_BIN_DIR/kubectl" ]]; then
  echo "Downloaded tools did not validate as OpenShift $OPENSHIFT_VERSION." >&2
  echo "oc=$oc_version openshift-install=$installer_version kubectl=$kubectl_version" >&2
  exit 1
fi

hash -r
cat <<DONE
OpenShift tools synchronized successfully:
  oc:                $INSTALL_BIN_DIR/oc ($oc_version)
  kubectl:           $INSTALL_BIN_DIR/kubectl ($kubectl_version)
  openshift-install: $INSTALL_BIN_DIR/openshift-install ($installer_version)
DONE
