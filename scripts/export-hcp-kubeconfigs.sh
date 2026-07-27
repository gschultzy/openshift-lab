#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=scripts/lib/hcp-tenants.sh
source scripts/lib/hcp-tenants.sh

ROOT_DIR="$PWD"
SITE_A_KUBECONFIG="${SITE_A_KUBECONFIG:-$ENV_SITE_A_KUBECONFIG}"
SITE_B_KUBECONFIG="${SITE_B_KUBECONFIG:-$ENV_SITE_B_KUBECONFIG}"
HCP_NAMESPACE="${HCP_NAMESPACE:-$ENV_HCP_NAMESPACE}"
OUT_DIR="${HCP_KUBECONFIG_OUT_DIR:-$ENV_HCP_KUBECONFIG_DIR}"
HCP_BIN="${HCP_BIN:-}"

if [[ -z "$HCP_BIN" ]]; then
  if [[ -x "$ENV_BUILD_ROOT/bin/hcp" ]]; then
    HCP_BIN="$ENV_BUILD_ROOT/bin/hcp"
  elif command -v hcp >/dev/null 2>&1; then
    HCP_BIN="$(command -v hcp)"
  else
    HCP_BIN=""
  fi
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

extract_one() {
  local label="$1"
  local kubeconfig="$2"
  local ns="$3"
  local name="$4"
  local out="$5"
  local tmp="${out}.tmp"

  echo
  echo "### $label"
  echo "Management kubeconfig : $kubeconfig"
  echo "HostedCluster        : $ns/$name"
  echo "Output kubeconfig    : $out"

  if [[ ! -s "$kubeconfig" ]]; then
    echo "ERROR: management kubeconfig is missing or empty: $kubeconfig" >&2
    return 1
  fi

  echo "API server: $(oc --kubeconfig "$kubeconfig" whoami --show-server 2>/dev/null || true)"

  if ! oc --kubeconfig "$kubeconfig" get namespace "$ns" >/dev/null 2>&1; then
    echo "ERROR: namespace $ns not found on this management/hosting cluster." >&2
    echo "Available likely namespaces:" >&2
    oc --kubeconfig "$kubeconfig" get ns --no-headers 2>/dev/null | awk '{print $1}' | egrep -i 'clusters|hcp|hypershift|hosted' || true
    return 1
  fi

  if ! oc --kubeconfig "$kubeconfig" -n "$ns" get hostedcluster "$name" >/dev/null 2>&1; then
    echo "ERROR: HostedCluster $ns/$name not found on this management/hosting cluster." >&2
    echo "HostedClusters found:" >&2
    oc --kubeconfig "$kubeconfig" get hostedcluster -A 2>/dev/null || true
    return 1
  fi

  rm -f "$tmp" "$out"

  if [[ -n "$HCP_BIN" && -x "$HCP_BIN" ]]; then
    echo "Trying hcp CLI: $HCP_BIN"
    if KUBECONFIG="$kubeconfig" "$HCP_BIN" create kubeconfig --namespace "$ns" --name "$name" > "$tmp" 2>"${tmp}.err"; then
      if [[ -s "$tmp" ]] && grep -q '^apiVersion:' "$tmp" && grep -q '^clusters:' "$tmp"; then
        mv "$tmp" "$out"
        rm -f "${tmp}.err"
        chmod 600 "$out"
        echo "Wrote kubeconfig with hcp CLI: $out"
        return 0
      fi
    fi
    echo "hcp CLI export did not produce a complete kubeconfig. Falling back to admin kubeconfig secret."
    if [[ -s "${tmp}.err" ]]; then
      sed 's/^/  hcp: /' "${tmp}.err" >&2 || true
    fi
  else
    echo "hcp CLI not found. Falling back to admin kubeconfig secret."
  fi

  local secret=""
  local secret_ns=""
  for candidate_ns in "$ns" "clusters-${name}"; do
    for candidate in "${name}-admin-kubeconfig" "admin-kubeconfig"; do
      if oc --kubeconfig "$kubeconfig" -n "$candidate_ns" get secret "$candidate" >/dev/null 2>&1; then
        secret="$candidate"
        secret_ns="$candidate_ns"
        break 2
      fi
    done
  done

  if [[ -z "$secret" ]]; then
    for candidate_ns in "$ns" "clusters-${name}"; do
      secret="$(oc --kubeconfig "$kubeconfig" -n "$candidate_ns" get secret -o name 2>/dev/null \
        | sed 's#^secret/##' \
        | egrep -i "(^${name}.*admin.*kubeconfig$|admin.*kubeconfig|kubeconfig)" \
        | head -1 || true)"
      if [[ -n "$secret" ]]; then
        secret_ns="$candidate_ns"
        break
      fi
    done
  fi

  if [[ -z "$secret" ]]; then
    echo "ERROR: Could not find an admin kubeconfig secret for HostedCluster $ns/$name." >&2
    echo "Secrets containing kubeconfig/admin:" >&2
    for candidate_ns in "$ns" "clusters-${name}"; do
      echo "# Namespace: $candidate_ns" >&2
      oc --kubeconfig "$kubeconfig" -n "$candidate_ns" get secret 2>/dev/null | egrep -i 'admin|kubeconfig|kubeadmin' || true
    done
    return 1
  fi

  echo "Trying secret: $secret_ns/$secret"
  local encoded=""
  encoded="$(oc --kubeconfig "$kubeconfig" -n "$secret_ns" get secret "$secret" -o jsonpath='{.data.kubeconfig}' 2>/dev/null || true)"
  if [[ -z "$encoded" ]]; then
    echo "ERROR: Secret $secret_ns/$secret exists but does not contain .data.kubeconfig" >&2
    echo "Available secret keys:" >&2
    oc --kubeconfig "$kubeconfig" -n "$secret_ns" get secret "$secret" -o go-template='{{range $k,$v := .data}}{{printf "%s\n" $k}}{{end}}' 2>/dev/null || true
    return 1
  fi

  printf '%s' "$encoded" | base64 -d > "$tmp"
  if [[ ! -s "$tmp" ]] || ! grep -q '^apiVersion:' "$tmp" || ! grep -q '^clusters:' "$tmp"; then
    echo "ERROR: decoded kubeconfig from $secret_ns/$secret is empty or incomplete." >&2
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$out"
  chmod 600 "$out"
  echo "Wrote kubeconfig from secret $secret_ns/$secret: $out"
}

while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
  if [[ "$site" == "$ENV_SITE_A_CLUSTER_NAME" ]]; then
    site_kubeconfig="$SITE_A_KUBECONFIG"
  elif [[ "$site" == "$ENV_SITE_B_CLUSTER_NAME" ]]; then
    site_kubeconfig="$SITE_B_KUBECONFIG"
  else
    echo "ERROR: unknown site in HCP tenant list: $site" >&2
    exit 1
  fi
  extract_one "$(hcp_tenant_site_label "$site") $name" "$site_kubeconfig" "$HCP_NAMESPACE" "$name" "$OUT_DIR/${name}.kubeconfig"
done < <(hcp_tenants)

cat <<MSG

Done. Test the hosted clusters with:

  for k in "$OUT_DIR"/*.kubeconfig; do
    echo "### \$k"
    oc --kubeconfig "\$k" get clusterversion,nodes
  done

Tip: the HostedCluster CRs for this repo are created on Site-A/Site-B in namespace '$HCP_NAMESPACE', not in a 'clusters' namespace on the hub SNO.
MSG
