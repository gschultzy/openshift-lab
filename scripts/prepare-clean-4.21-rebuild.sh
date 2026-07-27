#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/inventory-env.sh
source scripts/lib/inventory-env.sh

EXPECTED_RELEASE="$(./scripts/lib/inventory-value.py --file inventories/env/group_vars/all/main.yml ocp_release_version)"
if [[ "$EXPECTED_RELEASE" != 4.21.* ]]; then
  echo "This repository is not pinned to OpenShift 4.21: $EXPECTED_RELEASE" >&2
  exit 1
fi

cat <<MSG
This prepares the local repository for a clean OpenShift $EXPECTED_RELEASE rebuild.
It does not delete running clusters or Pure volumes.

Before continuing, use the existing hub while it is reachable to delete resources in this order:
  ./scripts/hcp-delete.sh
  # Run this destructive step only when Portworx was installed on the spokes:
  CONFIRM_PORTWORX_WIPE=true ./scripts/portworx-uninstall-and-wipe-spokes.sh
  CONFIRM_DELETE_SITE_B=true ./scripts/site-b-delete.sh
  CONFIRM_DELETE_SITE_A=true ./scripts/site-a-delete.sh
  CONFIRM_DELETE_HUB=true ./scripts/hub-delete.sh

The preparation step archives any remaining generated state so the 4.21 runner
cannot accidentally resume the previous installation.
MSG

if [[ "${CONFIRM_PREPARE_421_REBUILD:-false}" != "true" ]]; then
  echo
  echo "Run again with:"
  echo "  CONFIRM_PREPARE_421_REBUILD=true ./scripts/prepare-clean-4.21-rebuild.sh"
  exit 1
fi

if [[ -d "$ENV_BUILD_ROOT" ]]; then
  backup="${ENV_BUILD_ROOT%/*}/$(basename "$ENV_BUILD_ROOT")-pre-4.21-$(date +%Y%m%d-%H%M%S)"
  mv "$ENV_BUILD_ROOT" "$backup"
  echo "Archived generated state to: $backup"
else
  echo "No generated build state found at: $ENV_BUILD_ROOT"
fi

rm -f .venv/bin/oc .venv/bin/kubectl .venv/bin/openshift-install 2>/dev/null || true

echo
cat <<MSG
Local state is ready for OpenShift $EXPECTED_RELEASE.
Next run:
  ./scripts/bootstrap-ubuntu-24.04.sh
  source .venv/bin/activate
  ./scripts/run-full-hub-and-spoke.sh
MSG
