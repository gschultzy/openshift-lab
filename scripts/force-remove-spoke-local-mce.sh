#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for entry in \
  "Site-A:build/hub-sno/site-a/auth/kubeconfig" \
  "Site-B:build/hub-sno/site-b/auth/kubeconfig"; do
  display="${entry%%:*}"
  k="${entry#*:}"

  if [[ ! -s "$k" ]]; then
    echo "ERROR: missing kubeconfig for $display: $k" >&2
    exit 1
  fi

  echo "================================================================================"
  echo "Force removing stale local MCE from $display"
  echo "================================================================================"
  oc --kubeconfig "$k" whoami --show-server || true

  echo "# Remove stale ACM/MCE admission webhooks"
  for kind in validatingwebhookconfiguration mutatingwebhookconfiguration; do
    oc --kubeconfig "$k" get "$kind" -o json 2>/dev/null \
      | jq -r '.items[]?
        | select(
            any(.webhooks[]?; ((.clientConfig.service.namespace // "")
              | test("^(open-cluster-management|open-cluster-management-hub|multicluster-engine)$")))
            or (.metadata.name | test("(multicluster|mce|cluster-manager|open-cluster-management)"; "i"))
          )
        | .metadata.name' \
      | sort -u \
      | while read -r wh; do
          [[ -n "$wh" ]] || continue
          echo "Deleting $kind/$wh"
          oc --kubeconfig "$k" delete "$kind" "$wh" --ignore-not-found --wait=false || true
        done
  done

  echo "# Patch/delete MultiClusterEngine objects"
  oc --kubeconfig "$k" get multiclusterengine -o json 2>/dev/null \
    | jq -r '.items[]?.metadata.name' \
    | while read -r name; do
        [[ -n "$name" ]] || continue
        echo "MCE before patch: $name"
        oc --kubeconfig "$k" get multiclusterengine "$name" -o json | jq '{name:.metadata.name,deletionTimestamp:.metadata.deletionTimestamp,finalizers:.metadata.finalizers,status:.status.phase}' || true
        oc --kubeconfig "$k" patch multiclusterengine "$name" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' || true
        oc --kubeconfig "$k" patch multiclusterengine "$name" --type=merge -p '{"metadata":{"finalizers":null}}' || true
        oc --kubeconfig "$k" delete multiclusterengine "$name" --ignore-not-found --wait=false || true
      done

  echo "# Patch/delete MultiClusterHub objects"
  oc --kubeconfig "$k" get multiclusterhub -A -o json 2>/dev/null \
    | jq -r '.items[]? | [.metadata.namespace, .metadata.name] | @tsv' \
    | while IFS=$'\t' read -r ns name; do
        [[ -n "$ns" && -n "$name" ]] || continue
        oc --kubeconfig "$k" -n "$ns" patch multiclusterhub "$name" --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' || true
        oc --kubeconfig "$k" -n "$ns" patch multiclusterhub "$name" --type=merge -p '{"metadata":{"finalizers":null}}' || true
        oc --kubeconfig "$k" -n "$ns" delete multiclusterhub "$name" --ignore-not-found --wait=false || true
      done

  echo "# If MCE still exists, remove stale local MCE CRDs from this spoke"
  if oc --kubeconfig "$k" get multiclusterengine -A --no-headers 2>/dev/null | grep -q .; then
    for crd in \
      multiclusterengines.multicluster.openshift.io \
      multiclusterhubs.operator.open-cluster-management.io \
      managedclusteraddons.addon.open-cluster-management.io; do
      if oc --kubeconfig "$k" get crd "$crd" >/dev/null 2>&1; then
        echo "Deleting CRD $crd"
        oc --kubeconfig "$k" patch crd "$crd" --type=merge -p '{"metadata":{"finalizers":[]}}' || true
        oc --kubeconfig "$k" delete crd "$crd" --ignore-not-found --wait=false || true
      fi
    done
  fi

  echo "# Result"
  oc --kubeconfig "$k" get multiclusterengine -A 2>/dev/null || echo "No local MultiClusterEngine API/resources remain on $display"
  echo
done
