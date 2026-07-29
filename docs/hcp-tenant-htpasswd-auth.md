# Shared administrator for hub, spokes, and HCP tenants

The repository configures one lab administrator across:

- `local-cluster` (`lab-sno`)
- `site-a`
- `site-b`
- `site-a-hcp-t1-px`
- `site-a-hcp-t2-kv`
- `site-b-hcp-t1-px`
- `site-b-hcp-t2-kv`

## Pod 74 defaults

```text
username: admin
password: Password1!
```

The defaults work immediately after applying the ZIP. For a persistent environment, override them in the encrypted file `inventories/env/group_vars/all/vault.yml`:

```yaml
vault_cluster_admin_username: "admin"
vault_cluster_admin_password: "CHANGE_ME"
```

## How it works

Standard OpenShift clusters receive these resources through RHACM Governance:

- `Secret/openshift-config/lab-admin-htpasswd`
- `OAuth/cluster` identity provider `local-htpasswd`
- `ClusterRoleBinding/lab-admin-cluster-admin`

The hub and any reachable physical spokes are also bootstrapped directly so login does not have to wait for policy propagation. RHACM remains the continuous source of truth.

For HCP tenants, authentication is configured on the hosting cluster through each `HostedCluster.spec.configuration.oauth` field. The guest `ClusterRoleBinding` is applied after its system-admin kubeconfig is exported, and RHACM continuously enforces that binding after import.

## Automatic entry points

The shared account is reconciled automatically by:

```bash
./scripts/run.sh
./scripts/run-full-hub-and-spoke.sh
./scripts/hcp-create.sh
```

To reconcile only authentication and RBAC:

```bash
./scripts/configure-lab-admin.sh
```

The old command remains as a compatibility wrapper:

```bash
./scripts/apply-hcp-tenant-htpasswd-policy.sh
```

## Verify RHACM policy state

```bash
export KUBECONFIG="$PWD/build/lab-sno/install/auth/kubeconfig"

oc -n lab-admin-policies get \
  policy,placementrule,placementbinding

oc get managedcluster \
  -L openshift-lab.redhat.com/admin-standard,openshift-lab.redhat.com/admin-hcp
```

## Verify standard clusters

```bash
for kubeconfig in \
  build/lab-sno/install/auth/kubeconfig \
  build/lab-sno/site-a/auth/kubeconfig \
  build/lab-sno/site-b/auth/kubeconfig; do
  echo "===== $kubeconfig ====="
  oc --kubeconfig "$kubeconfig" get clusterrolebinding lab-admin-cluster-admin
  oc --kubeconfig "$kubeconfig" get oauth cluster -o json | \
    jq -r '.spec.identityProviders[] | select(.name == "local-htpasswd")'
done
```

## Verify HCP tenants

```bash
for kubeconfig in build/lab-sno/hcp-kubeconfigs/*.kubeconfig; do
  echo "===== $kubeconfig ====="
  oc --kubeconfig "$kubeconfig" get clusterrolebinding lab-admin-cluster-admin
  oc --kubeconfig "$kubeconfig" auth can-i '*' '*' --as=admin
done
```

Keep the exported system-admin kubeconfigs as recovery credentials. Adding an HTPasswd identity provider does not replace those certificate-based kubeconfigs.

## RHACM label selector validation

ManagedCluster label values are strings. The shared-admin policy templates quote
`"true"` explicitly and use a server-side dry run before applying policies. This
prevents YAML from converting the selector value to a Boolean, which the
Kubernetes API rejects for `matchLabels`.
