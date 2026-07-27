#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/inventory-env.sh
source "$ROOT_DIR/scripts/lib/inventory-env.sh"
HUB_KUBECONFIG="${HUB_KUBECONFIG:-$ENV_HUB_KUBECONFIG}"
SITEA_KUBECONFIG="${SITEA_KUBECONFIG:-$ENV_SITE_A_KUBECONFIG}"
SITEB_KUBECONFIG="${SITEB_KUBECONFIG:-$ENV_SITE_B_KUBECONFIG}"

for kc in "$HUB_KUBECONFIG" "$SITEA_KUBECONFIG" "$SITEB_KUBECONFIG"; do
  echo
  echo "============================================================"
  echo "KUBECONFIG: $kc"
  if [ ! -f "$kc" ]; then
    echo "Missing"
    continue
  fi
  echo "API: $(oc --kubeconfig "$kc" whoami --show-server 2>/dev/null || true)"
  echo
  echo "# ConsoleCLIDownload hcp objects"
  oc --kubeconfig "$kc" get consoleclidownload hcp-cli-download hypershift-cli-download -o wide 2>/dev/null || true
  echo
  echo "# hcp-cli-download YAML links"
  oc --kubeconfig "$kc" get consoleclidownload hcp-cli-download -o yaml 2>/dev/null | sed -n '/links:/,/^status:/p' || true
  echo
  echo "# Routes/services/endpoints mentioning hcp/hypershift/cli/mce"
  oc --kubeconfig "$kc" get route,svc,endpointslice -A 2>/dev/null | grep -Ei 'hcp.*cli|hypershift.*cli|cli.*download|multicluster-engine' || true
done
