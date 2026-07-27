#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .venv/bin/activate ]]; then
  # shellcheck source=/dev/null
  source .venv/bin/activate
else
  echo "Missing .venv. Run ./scripts/bootstrap-ubuntu-24.04.sh first on the Ubuntu bastion." >&2
  exit 1
fi

# shellcheck source=scripts/lib/hcp-tenants.sh
source scripts/lib/hcp-tenants.sh

INV="${INV:-$ENV_INVENTORY_FILE}"
ROOT_DIR="$PWD"

if [[ -n "${ANSIBLE_VAULT_PASSWORD_FILE:-}" ]]; then
  VAULT_ARGS=(--vault-password-file "$ANSIBLE_VAULT_PASSWORD_FILE")
else
  VAULT_PASSWORD_FILE_TMP="$(mktemp)"
  chmod 600 "$VAULT_PASSWORD_FILE_TMP"
  trap 'rm -f "$VAULT_PASSWORD_FILE_TMP"' EXIT

  read -r -s -p "Vault password: " VAULT_PASSWORD
  echo
  printf '%s\n' "$VAULT_PASSWORD" > "$VAULT_PASSWORD_FILE_TMP"
  unset VAULT_PASSWORD

  VAULT_ARGS=(--vault-password-file "$VAULT_PASSWORD_FILE_TMP")
fi

export HUB_KUBECONFIG="${HUB_KUBECONFIG:-$ENV_HUB_KUBECONFIG}"
export KUBECONFIG="$HUB_KUBECONFIG"

ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/17_validate_hub_context.yml
ansible-playbook -i "$INV" "${VAULT_ARGS[@]}" playbooks/28_apply_hcp_tenant_htpasswd_policy.yml

TENANT_USER="$(inventory_value hcp_tenant_admin_username)"
TENANT_PASSWORD_NOTE="$(inventory_value hcp_tenant_admin_password_note)"
TENANT_POLICY_NAMESPACE="$(inventory_value hcp_tenant_policy_namespace)"
HCP_NAMESPACE="$(inventory_value site_a_hcp_namespace)"

cat <<EOM

HCP tenant HTPasswd OAuth policy has been applied from the hub to the hosting clusters.

Tenant login:
  username: $TENANT_USER
  password: $TENANT_PASSWORD_NOTE

Check policy status:
  oc --kubeconfig $HUB_KUBECONFIG -n $TENANT_POLICY_NAMESPACE get policy,placement,placementdecision,placementbinding

Verify HostedCluster OAuth config on the hosting clusters:
EOM

while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
  if [[ "$site" == "$ENV_SITE_A_CLUSTER_NAME" ]]; then
    k="$ENV_SITE_A_KUBECONFIG"
  elif [[ "$site" == "$ENV_SITE_B_CLUSTER_NAME" ]]; then
    k="$ENV_SITE_B_KUBECONFIG"
  else
    continue
  fi
  printf '  oc --kubeconfig %s -n %s get hostedcluster %s -o yaml | egrep -A12 '''oauth:|identityProviders:|HTPasswd|fileData'''
' "$k" "$HCP_NAMESPACE" "$name"
done < <(hcp_tenants)

cat <<'EOM'

Cluster-admin RBAC is not part of HostedCluster OAuth sync. To grant it after tenant APIs are reachable:
EOM
while IFS='|' read -r site name mc cluster_cidr service_cidr extra_disks tenant_px_sc guest_sc; do
  printf '  oc --kubeconfig %s/%s.kubeconfig adm policy add-cluster-role-to-user cluster-admin %s
' "$ENV_HCP_KUBECONFIG_DIR" "$name" "$TENANT_USER"
done < <(hcp_tenants)
