#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HUB_KUBECONFIG="${HUB_KUBECONFIG:-$ROOT_DIR/build/hub-sno/install/auth/kubeconfig}"
SITEA_KUBECONFIG="${SITEA_KUBECONFIG:-$ROOT_DIR/build/hub-sno/site-a/auth/kubeconfig}"
SITEB_KUBECONFIG="${SITEB_KUBECONFIG:-$ROOT_DIR/build/hub-sno/site-b/auth/kubeconfig}"

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
