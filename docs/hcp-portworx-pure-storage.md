# HCP create/delete runbook

This lab has one supported HCP lifecycle:

```text
{{ cluster_name }} = RHACM + MCE
site-a  = RHACM managed hosting cluster
site-b  = RHACM managed hosting cluster
```

Do not install local MCE on Site-A or Site-B. The hub enables the HyperShift add-on on the spokes.

## Create and import HCP tenants

```bash
cd /path/to/openshift-lab
source .venv/bin/activate

./scripts/hcp-create.sh
```

This creates and imports four tenants:

| Site | HostedCluster | RHACM ManagedCluster | Shape | Pod CIDR | Service CIDR |
|---|---|---|---|---|---|
| Site-A | `site-a-hcp-t1-px` | `site-a-hcp-t1-px` | PX tenant, extra FADA disks | `{{ hcp_tenants[0].cluster_cidr }}` | `{{ hcp_tenants[0].service_cidr }}` |
| Site-A | `site-a-hcp-t2-kv` | `site-a-hcp-t2-kv` | KubeVirt tenant, no extra PX disks | `{{ hcp_tenants[1].cluster_cidr }}` | `{{ hcp_tenants[1].service_cidr }}` |
| Site-B | `site-b-hcp-t1-px` | `site-b-hcp-t1-px` | PX tenant, extra FADA disks | `{{ hcp_tenants[2].cluster_cidr }}` | `{{ hcp_tenants[2].service_cidr }}` |
| Site-B | `site-b-hcp-t2-kv` | `site-b-hcp-t2-kv` | KubeVirt tenant, no extra PX disks | `{{ hcp_tenants[3].cluster_cidr }}` | `{{ hcp_tenants[3].service_cidr }}` |

The tenant list is defined in `scripts/lib/hcp-tenants.sh`. RHACM ManagedCluster names intentionally match HostedCluster names.

## Delete tenants

```bash
./scripts/hcp-delete.sh
```

For a lab-only force cleanup:

```bash
HCP_FORCE_CLEANUP=true ./scripts/hcp-delete.sh
```

## Storage defaults

| Role | StorageClass |
|---|---|
| Worker VM root/boot volumes | `hcp-pxe-boot` |
| Hosted control-plane etcd PVCs | `hcp-pxe-etcd-pxfast` |
| General guest storage mapping | `hcp-pxe-data` |
| PX tenant extra disks | `hcp-fada-data` |
| OpenShift Virtualization vmStateStorageClass | `vmstate` |

The `*-t1-px` tenants get three extra disks on `hcp-fada-data` for tenant Portworx storage pools. The `*-t2-kv` tenants do not get extra PX disks.

## Checks

```bash
oc --kubeconfig build/{{ cluster_name }}/install/auth/kubeconfig get managedcluster
oc --kubeconfig build/{{ cluster_name }}/site-a/auth/kubeconfig -n clusters get hostedcluster,nodepool
oc --kubeconfig build/{{ cluster_name }}/site-b/auth/kubeconfig -n clusters get hostedcluster,nodepool

for k in build/{{ cluster_name }}/hcp-kubeconfigs/*.kubeconfig; do
  echo "### $k"
  oc --kubeconfig "$k" get clusterversion,nodes
fi
```
