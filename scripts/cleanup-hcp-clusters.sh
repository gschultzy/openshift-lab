#!/usr/bin/env bash
set -euo pipefail

# Cleanly remove all HCP tenant clusters from this lab.
# Default tenants are defined in scripts/lib/hcp-tenants.sh:
#   site-a-hcp-t1-px, site-a-hcp-t2-kv, site-b-hcp-t1-px, site-b-hcp-t2-kv
#
# Normal mode performs a clean delete and waits.
# Set HCP_FORCE_CLEANUP=true only for lab/test clusters stuck in Terminating.

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT_DIR"

# shellcheck source=scripts/lib/hcp-tenants.sh
source scripts/lib/hcp-tenants.sh

HUB_KUBECONFIG="${HUB_KUBECONFIG:-$ENV_HUB_KUBECONFIG}"
SITEA_KUBECONFIG="${SITEA_KUBECONFIG:-$ENV_SITE_A_KUBECONFIG}"
SITEB_KUBECONFIG="${SITEB_KUBECONFIG:-$ENV_SITE_B_KUBECONFIG}"

HCP_NAMESPACE="${HCP_NAMESPACE:-clusters}"
HCP_KUBECONFIG_OUT_DIR="${HCP_KUBECONFIG_OUT_DIR:-$ENV_HCP_KUBECONFIG_DIR}"
HCP_WAIT_SECONDS="${HCP_WAIT_SECONDS:-900}"
HCP_WAIT_INTERVAL="${HCP_WAIT_INTERVAL:-15}"
HCP_FORCE_CLEANUP="${HCP_FORCE_CLEANUP:-false}"

say() { printf '\n### %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
server_for() { oc --kubeconfig "$1" whoami --show-server 2>/dev/null || true; }


repair_dead_addon_conversion() {
  local kubeconfig="$1"
  local label="$2"
  local crd=managedclusteraddons.addon.open-cluster-management.io

  oc --kubeconfig "$kubeconfig" get crd "$crd" >/dev/null 2>&1 || return 0

  local strategy svc_ns svc_name
  strategy="$(oc --kubeconfig "$kubeconfig" get crd "$crd" -o jsonpath='{.spec.conversion.strategy}' 2>/dev/null || true)"
  svc_ns="$(oc --kubeconfig "$kubeconfig" get crd "$crd" -o jsonpath='{.spec.conversion.webhook.clientConfig.service.namespace}' 2>/dev/null || true)"
  svc_name="$(oc --kubeconfig "$kubeconfig" get crd "$crd" -o jsonpath='{.spec.conversion.webhook.clientConfig.service.name}' 2>/dev/null || true)"

  if [[ "$strategy" == "Webhook" && -n "$svc_ns" && -n "$svc_name" ]]; then
    if ! oc --kubeconfig "$kubeconfig" -n "$svc_ns" get svc "$svc_name" >/dev/null 2>&1; then
      echo "# ${label}: repairing stale ${crd} conversion webhook; missing service ${svc_ns}/${svc_name}"
      oc --kubeconfig "$kubeconfig" get crd "$crd" -o yaml > "/tmp/${label}-${crd}.backup.yaml" 2>/dev/null || true
      oc --kubeconfig "$kubeconfig" patch crd "$crd" --type=json \
        -p='[{"op":"replace","path":"/spec/conversion","value":{"strategy":"None"}}]' || true
    fi
  fi
}

require_contexts() {
  [[ -s "$HUB_KUBECONFIG" ]] || die "Missing hub kubeconfig: $HUB_KUBECONFIG"
  [[ -s "$SITEA_KUBECONFIG" ]] || die "Missing Site-A kubeconfig: $SITEA_KUBECONFIG"
  [[ -s "$SITEB_KUBECONFIG" ]] || die "Missing Site-B kubeconfig: $SITEB_KUBECONFIG"

  HUB_API="$(server_for "$HUB_KUBECONFIG")"
  SITEA_API="$(server_for "$SITEA_KUBECONFIG")"
  SITEB_API="$(server_for "$SITEB_KUBECONFIG")"

  echo "Hub API:    $HUB_API"
  echo "Site-A API: $SITEA_API"
  echo "Site-B API: $SITEB_API"

  [[ "$HUB_API" == *"$ENV_HUB_API_HOST"* ]] || die "HUB_KUBECONFIG does not point to the configured hub. Refusing to continue."
  [[ "$SITEA_API" == *"site-a"* ]] || die "SITEA_KUBECONFIG does not look like site-a. Refusing to continue."
  [[ "$SITEB_API" == *"site-b"* ]] || die "SITEB_KUBECONFIG does not look like site-b. Refusing to continue."
}

disable_discovery_import() {
  local hub_ns="$1"
  local hcp_name="$2"

  say "Disable RHACM discovered-cluster import for ${hub_ns}/${hcp_name}"
  local dcs
  dcs="$(oc --kubeconfig "$HUB_KUBECONFIG" -n "$hub_ns" get discoveredcluster \
    -l hypershift.open-cluster-management.io/hc-name="$hcp_name" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"

  if [[ -z "$dcs" ]]; then
    echo "No DiscoveredCluster found for ${hub_ns}/${hcp_name}."
    return 0
  fi

  while IFS= read -r dc; do
    [[ -z "$dc" ]] && continue
    echo "Patching ${hub_ns}/${dc}: importAsManagedCluster=false"
    oc --kubeconfig "$HUB_KUBECONFIG" -n "$hub_ns" patch discoveredcluster "$dc" \
      --type=merge -p '{"spec":{"importAsManagedCluster":false}}' || true
  done <<< "$dcs"
}

delete_managedcluster() {
  local mc="$1"
  say "Delete RHACM ManagedCluster ${mc}"
  oc --kubeconfig "$HUB_KUBECONFIG" delete managedcluster "$mc" --ignore-not-found --wait=false || true
  oc --kubeconfig "$HUB_KUBECONFIG" -n "$mc" delete klusterletaddonconfig "$mc" --ignore-not-found --wait=false 2>/dev/null || true
  oc --kubeconfig "$HUB_KUBECONFIG" -n "$mc" delete secret auto-import-secret --ignore-not-found --wait=false 2>/dev/null || true
}

wait_for_import_namespace_cleanup() {
  local mc="$1"
  local end=$((SECONDS + HCP_WAIT_SECONDS))

  say "Wait for RHACM import namespace ${mc} cleanup"
  oc --kubeconfig "$HUB_KUBECONFIG" delete ns "$mc" --ignore-not-found --wait=false || true

  while (( SECONDS < end )); do
    if ! oc --kubeconfig "$HUB_KUBECONFIG" get ns "$mc" >/dev/null 2>&1; then
      echo "RHACM import namespace ${mc} cleanup complete."
      return 0
    fi

    local phase deleting
    phase="$(oc --kubeconfig "$HUB_KUBECONFIG" get ns "$mc" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    deleting="$(oc --kubeconfig "$HUB_KUBECONFIG" get ns "$mc" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)"
    echo "Still cleaning RHACM import namespace ${mc}: phase=${phase:-unknown}, deletionTimestamp=${deleting:-none}"
    sleep "$HCP_WAIT_INTERVAL"
  done

  echo "RHACM import namespace ${mc} did not disappear within ${HCP_WAIT_SECONDS}s."
  if [[ "$HCP_FORCE_CLEANUP" == "true" ]]; then
    force_namespace_cleanup "$HUB_KUBECONFIG" "$mc"
    return 0
  fi

  echo "Re-run with HCP_FORCE_CLEANUP=true only if this is a lab/test cleanup."
  return 1
}

delete_hcp() {
  local kubeconfig="$1"
  local site_label="$2"
  local hcp_name="$3"

  say "Delete ${site_label} HCP ${HCP_NAMESPACE}/${hcp_name}"
  oc --kubeconfig "$kubeconfig" -n "$HCP_NAMESPACE" delete nodepool "$hcp_name" --ignore-not-found --wait=false || true
  oc --kubeconfig "$kubeconfig" -n "$HCP_NAMESPACE" delete hostedcluster "$hcp_name" --ignore-not-found --wait=false || true
}

patch_finalizers() {
  local kubeconfig="$1"
  local ns="$2"
  local obj="$3"
  oc --kubeconfig "$kubeconfig" -n "$ns" patch "$obj" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
}

finalize_namespace() {
  local kubeconfig="$1"
  local ns="$2"
  oc --kubeconfig "$kubeconfig" get ns "$ns" >/dev/null 2>&1 || return 0
  echo "Force-finalizing namespace ${ns}"
  oc --kubeconfig "$kubeconfig" get ns "$ns" -o json \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); d.setdefault("metadata",{})["finalizers"]=[]; d.setdefault("spec",{})["finalizers"]=[]; print(json.dumps(d))' \
    | oc --kubeconfig "$kubeconfig" replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
}

force_namespace_cleanup() {
  local kubeconfig="$1"
  local ns="$2"
  oc --kubeconfig "$kubeconfig" get ns "$ns" >/dev/null 2>&1 || return 0

  echo "Force-cleaning namespaced resources in ${ns}"
  local resources
  resources="$(oc --kubeconfig "$kubeconfig" api-resources --namespaced=true --verbs=list -o name 2>/dev/null | grep -v '^events' || true)"
  for r in $resources; do
    local objs
    objs="$(oc --kubeconfig "$kubeconfig" -n "$ns" get "$r" -o name --ignore-not-found 2>/dev/null || true)"
    [[ -z "$objs" ]] && continue
    while IFS= read -r obj; do
      [[ -z "$obj" ]] && continue
      oc --kubeconfig "$kubeconfig" -n "$ns" patch "$obj" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      oc --kubeconfig "$kubeconfig" -n "$ns" delete "$obj" --ignore-not-found --force --grace-period=0 --wait=false >/dev/null 2>&1 || true
    done <<< "$objs"
  done
  finalize_namespace "$kubeconfig" "$ns"
}

force_site_cleanup() {
  local kubeconfig="$1"
  local site_label="$2"
  local hcp_name="$3"
  local mc_name="$4"
  local hcp_hosting_ns="clusters-${hcp_name}"
  local klusterlet_ns="klusterlet-${mc_name}"

  say "FORCE cleanup for ${site_label}"
  patch_finalizers "$kubeconfig" "$HCP_NAMESPACE" "nodepool/${hcp_name}"
  patch_finalizers "$kubeconfig" "$HCP_NAMESPACE" "hostedcluster/${hcp_name}"
  oc --kubeconfig "$kubeconfig" -n "$HCP_NAMESPACE" delete nodepool "$hcp_name" --ignore-not-found --force --grace-period=0 --wait=false || true
  oc --kubeconfig "$kubeconfig" -n "$HCP_NAMESPACE" delete hostedcluster "$hcp_name" --ignore-not-found --force --grace-period=0 --wait=false || true

  oc --kubeconfig "$kubeconfig" delete ns "$hcp_hosting_ns" "$klusterlet_ns" --ignore-not-found --wait=false || true
  force_namespace_cleanup "$kubeconfig" "$hcp_hosting_ns"
  force_namespace_cleanup "$kubeconfig" "$klusterlet_ns"
}

wait_for_site_cleanup() {
  local kubeconfig="$1"
  local site_label="$2"
  local hcp_name="$3"
  local mc_name="$4"
  local hcp_hosting_ns="clusters-${hcp_name}"
  local klusterlet_ns="klusterlet-${mc_name}"
  local end=$((SECONDS + HCP_WAIT_SECONDS))

  say "Wait for ${site_label} cleanup"
  while (( SECONDS < end )); do
    local hc np hcp_ns kl_ns
    hc="$(oc --kubeconfig "$kubeconfig" -n "$HCP_NAMESPACE" get hostedcluster "$hcp_name" --ignore-not-found 2>/dev/null || true)"
    np="$(oc --kubeconfig "$kubeconfig" -n "$HCP_NAMESPACE" get nodepool "$hcp_name" --ignore-not-found 2>/dev/null || true)"
    hcp_ns="$(oc --kubeconfig "$kubeconfig" get ns "$hcp_hosting_ns" --ignore-not-found 2>/dev/null || true)"
    kl_ns="$(oc --kubeconfig "$kubeconfig" get ns "$klusterlet_ns" --ignore-not-found 2>/dev/null || true)"

    if [[ -z "$hc$np$hcp_ns$kl_ns" ]]; then
      echo "${site_label} cleanup complete."
      return 0
    fi

    echo "Still cleaning ${site_label}..."
    oc --kubeconfig "$kubeconfig" -n "$HCP_NAMESPACE" get hostedcluster,nodepool "$hcp_name" --ignore-not-found 2>/dev/null || true
    oc --kubeconfig "$kubeconfig" get ns "$hcp_hosting_ns" "$klusterlet_ns" --ignore-not-found 2>/dev/null || true
    sleep "$HCP_WAIT_INTERVAL"
  done

  echo "${site_label} cleanup did not complete within ${HCP_WAIT_SECONDS}s."
  if [[ "$HCP_FORCE_CLEANUP" == "true" ]]; then
    force_site_cleanup "$kubeconfig" "$site_label" "$hcp_name" "$mc_name"
  else
    echo "Re-run with HCP_FORCE_CLEANUP=true only if this is a lab/test cleanup."
    return 1
  fi
}

clean_local_files() {
  say "Remove local exported HCP kubeconfigs"
  while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
    rm -f "$HCP_KUBECONFIG_OUT_DIR/${name}.kubeconfig"
  done < <(hcp_tenants)
}

final_status() {
  say "Final status"
  echo "# Hub managed clusters"
  oc --kubeconfig "$HUB_KUBECONFIG" get managedcluster || true
  echo
  echo "# Site-A HCP resources"
  oc --kubeconfig "$SITEA_KUBECONFIG" -n "$HCP_NAMESPACE" get hostedcluster,nodepool 2>/dev/null || true
  while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
    [[ "$site" == "site-a" ]] || continue
    oc --kubeconfig "$SITEA_KUBECONFIG" get ns | egrep "clusters-${name}|klusterlet-${mc}" || true
  done < <(hcp_tenants)
  echo
  echo "# Site-B HCP resources"
  oc --kubeconfig "$SITEB_KUBECONFIG" -n "$HCP_NAMESPACE" get hostedcluster,nodepool 2>/dev/null || true
  while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
    [[ "$site" == "site-b" ]] || continue
    oc --kubeconfig "$SITEB_KUBECONFIG" get ns | egrep "clusters-${name}|klusterlet-${mc}" || true
  done < <(hcp_tenants)
}

main() {
  say "HCP cleanup plan"
  require_contexts
  echo
  echo "Force cleanup: ${HCP_FORCE_CLEANUP}"
  echo "Tenants to delete:"
  hcp_tenants | while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
    printf '  %-6s HostedCluster=%-18s RHACM=%s
' "$site" "$name" "$mc"
  done

  repair_dead_addon_conversion "$SITEA_KUBECONFIG" "Site-A"
  repair_dead_addon_conversion "$SITEB_KUBECONFIG" "Site-B"

  while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
    disable_discovery_import "$site" "$name"
  done < <(hcp_tenants)

  while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
    delete_managedcluster "$mc"
  done < <(hcp_tenants)

  while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
    wait_for_import_namespace_cleanup "$mc"
  done < <(hcp_tenants)

  while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
    case "$site" in
      site-a) kubeconfig="$SITEA_KUBECONFIG" ;;
      site-b) kubeconfig="$SITEB_KUBECONFIG" ;;
      *) echo "ERROR: unknown site $site" >&2; exit 1 ;;
    esac
    delete_hcp "$kubeconfig" "$(hcp_tenant_site_label "$site")" "$name"
  done < <(hcp_tenants)

  while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
    case "$site" in
      site-a) kubeconfig="$SITEA_KUBECONFIG" ;;
      site-b) kubeconfig="$SITEB_KUBECONFIG" ;;
      *) echo "ERROR: unknown site $site" >&2; exit 1 ;;
    esac
    wait_for_site_cleanup "$kubeconfig" "$(hcp_tenant_site_label "$site") $name" "$name" "$mc"
  done < <(hcp_tenants)

  clean_local_files
  final_status
  say "HCP cleanup completed"
}

main "$@"
