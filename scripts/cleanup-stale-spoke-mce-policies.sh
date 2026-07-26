#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

export KUBECONFIG="${KUBECONFIG:-$PWD/build/lab-sno/install/auth/kubeconfig}"

echo "Using kubeconfig: $KUBECONFIG"
echo "API server: $(oc whoami --show-server)"

oc -n site-a-policies delete policy site-a-mce-hcp-hosting --ignore-not-found
oc -n site-b-policies delete policy site-b-mce-hcp-hosting --ignore-not-found
rm -f build/lab-sno/site-a-hcp-policies/*mce*.yaml build/lab-sno/site-b-hcp-policies/*mce*.yaml 2>/dev/null || true
rm -f build/lab-sno/site-a-hcp-policies/*MCE*.yaml build/lab-sno/site-b-hcp-policies/*MCE*.yaml 2>/dev/null || true

echo
oc get policy -A | egrep 'site-[ab]-(mce|openshift|metallb|ingress|lvm)' || true
