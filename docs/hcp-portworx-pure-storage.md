# HCP create/delete runbook

This lab has one supported HCP lifecycle:

```text
hub-sno = RHACM + MCE
site-a  = RHACM managed hosting cluster
site-b  = RHACM managed hosting cluster
```

Do not install local MCE on Site-A or Site-B. The hub enables the HyperShift add-on on the spokes.

## Create and import HCP tenants

```bash
cd ~/OCP/ocp-sno-vsphere-ansible
source .venv/bin/activate

./scripts/hcp-create.sh
```

This creates and imports four tenants:

| Site | HostedCluster | RHACM ManagedCluster | Shape | Pod CIDR | Service CIDR |
|---|---|---|---|---|---|
| Site-A | `site-a-hcp-t1-px` | `site-a-hcp-t1-px` | PX tenant, extra FADA disks | `10.144.0.0/14` | `172.32.0.0/16` |
| Site-A | `site-a-hcp-t2-kv` | `site-a-hcp-t2-kv` | KubeVirt tenant, no extra PX disks | `10.148.0.0/14` | `172.33.0.0/16` |
| Site-B | `site-b-hcp-t1-px` | `site-b-hcp-t1-px` | PX tenant, extra FADA disks | `10.152.0.0/14` | `172.34.0.0/16` |
| Site-B | `site-b-hcp-t2-kv` | `site-b-hcp-t2-kv` | KubeVirt tenant, no extra PX disks | `10.156.0.0/14` | `172.35.0.0/16` |

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
oc --kubeconfig build/hub-sno/install/auth/kubeconfig get managedcluster
oc --kubeconfig build/hub-sno/site-a/auth/kubeconfig -n clusters get hostedcluster,nodepool
oc --kubeconfig build/hub-sno/site-b/auth/kubeconfig -n clusters get hostedcluster,nodepool

for k in build/hub-sno/hcp-kubeconfigs/*.kubeconfig; do
  echo "### $k"
  oc --kubeconfig "$k" get clusterversion,nodes
fi
```
