# HCP tenant HTPasswd authentication policy

This repo includes RHACM Governance policies that configure HTPasswd OAuth for all HCP guest clusters by managing the `HostedCluster` resources on their hosting clusters.

Default tenants:

| Site | HostedCluster |
|---|---|
| Site-A | `site-a-hcp-t1-px` |
| Site-A | `site-a-hcp-t2-kv` |
| Site-B | `site-b-hcp-t1-px` |
| Site-B | `site-b-hcp-t2-kv` |

In hosted control planes, OAuth configuration is synced from the hosting cluster through the `HostedCluster` resource. Do not manage the tenant `OAuth/cluster` object directly for this flow.

## Apply

```bash
./scripts/apply-hcp-tenant-htpasswd-policy.sh
```

## What it creates

On the Site-A hosting cluster:

- `Secret/clusters/htpasswd-site-a-hcp-tenants`
- OAuth configuration on `HostedCluster/clusters/site-a-hcp-t1-px`
- OAuth configuration on `HostedCluster/clusters/site-a-hcp-t2-kv`

On the Site-B hosting cluster:

- `Secret/clusters/htpasswd-site-b-hcp-tenants`
- OAuth configuration on `HostedCluster/clusters/site-b-hcp-t1-px`
- OAuth configuration on `HostedCluster/clusters/site-b-hcp-t2-kv`

## Credentials

```text
username: admin
password: pureuser
```

The password is stored in the policy as a bcrypt htpasswd hash.

## Verify

```bash
oc --kubeconfig build/hub-sno/install/auth/kubeconfig \
  -n hcp-tenant-auth-policies get policy,placement,placementdecision,placementbinding

for h in site-a-hcp-t1-px site-a-hcp-t2-kv; do
  oc --kubeconfig build/hub-sno/site-a/auth/kubeconfig \
    -n clusters get hostedcluster "$h" -o yaml | \
    egrep -A12 'oauth:|identityProviders:|HTPasswd|fileData'
done

for h in site-b-hcp-t1-px site-b-hcp-t2-kv; do
  oc --kubeconfig build/hub-sno/site-b/auth/kubeconfig \
    -n clusters get hostedcluster "$h" -o yaml | \
    egrep -A12 'oauth:|identityProviders:|HTPasswd|fileData'
done
```

## Cluster-admin role

The host-synced HCP configuration path covers control-plane configuration such as OAuth. A tenant `ClusterRoleBinding` is guest-cluster RBAC, not a `HostedCluster.spec.configuration` field. Apply it after tenant APIs are reachable:

```bash
for k in build/hub-sno/hcp-kubeconfigs/*.kubeconfig; do
  oc --kubeconfig "$k" adm policy add-cluster-role-to-user cluster-admin admin
 done
```
