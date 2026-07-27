#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/inventory-env.sh
source scripts/lib/inventory-env.sh

EXPECTED_MINOR="$(inventory_value ocp_version)"
EXPECTED_RELEASE="$(inventory_value ocp_release_version)"
ALLOW_MIXED="${ALLOW_MIXED_OPENSHIFT_RELEASE_STATE:-false}"

truthy_release_guard() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|Yes|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

fail_mismatch() {
  local found="$1" source="$2"
  cat >&2 <<MSG
OpenShift release mismatch detected.
  Repository baseline: $EXPECTED_RELEASE
  Existing state:      $found
  Source:              $source

This repository must not resume an installation from a different OpenShift minor.
Delete the old environment and run:
  CONFIRM_PREPARE_421_REBUILD=true ./scripts/prepare-clean-4.21-rebuild.sh
MSG
  exit 1
}

if truthy_release_guard "$ALLOW_MIXED"; then
  echo "WARNING: release-state guard disabled by ALLOW_MIXED_OPENSHIFT_RELEASE_STATE=$ALLOW_MIXED" >&2
  exit 0
fi

if [[ -s "$ENV_HUB_KUBECONFIG" ]] && command -v oc >/dev/null 2>&1; then
  current="$(timeout 15 oc --kubeconfig "$ENV_HUB_KUBECONFIG" \
    get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)"
  if [[ -n "$current" && "$current" != "$EXPECTED_MINOR".* ]]; then
    fail_mismatch "$current" "$ENV_HUB_KUBECONFIG"
  fi
fi

if [[ -d "$ENV_INSTALL_DIR" ]]; then
  while IFS= read -r version; do
    [[ -z "$version" ]] && continue
    if [[ "$version" != "$EXPECTED_MINOR".* ]]; then
      fail_mismatch "$version" "$ENV_INSTALL_DIR"
    fi
  done < <(grep -RhoE '4\.[0-9]+\.[0-9]+' "$ENV_INSTALL_DIR" 2>/dev/null | sort -u || true)
fi

echo "OpenShift release-state check passed: $EXPECTED_RELEASE"
