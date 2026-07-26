# OpenShift hub, Site-A, Site-B and HCP lab

This repo builds this lab:

```text
hub-sno = vSphere SNO hub with RHACM/MCE/Assisted Installer
site-a  = bare-metal OpenShift hosting cluster: b08-33, b08-34, b08-35
site-b  = bare-metal OpenShift hosting cluster: b08-36, b09-33, b09-34
HCPs    = hosted control planes created on Site-A and Site-B
```

Site-A and Site-B are **managed spoke / hosting clusters**. Do not install a second local RHACM/MCE hub on Site-A or Site-B. The hub manages them and enables the HyperShift add-on.

Detailed fixes and troubleshooting have been moved to [`docs/troubleshooting.md`](docs/troubleshooting.md).

---

## 1. Prep the bastion

Start on the Ubuntu 24.04 bastion
Create the Python environment and install requirements:

```bash
./scripts/bootstrap-ubuntu-24.04.sh
source .venv/bin/activate
```

For later shells:

```bash
cd ~/OCP/ocp-sno-vsphere-ansible
source .venv/bin/activate
```

Check the main lab config:

```bash
vi inventories/pod22/group_vars/all/main.yml
```

Important defaults in this lab:

```text
Hub API:        api.hub-sno.poc.local
Site-A API:     api.site-a.poc.local
Site-B API:     api.site-b.poc.local
Site-A nodes:   b08-33, b08-34, b08-35
Site-B nodes:   b08-36, b09-33, b09-34
Pure array:     10.23.22.50
```

The scripts ask for the Ansible Vault password once and reuse it. You can also provide a vault password file:

```bash
export ANSIBLE_VAULT_PASSWORD_FILE=/path/to/vault-password-file
```

---

## 2. Create and destroy the hub

Create the SNO hub VM and wait for OpenShift to install:

```bash
./scripts/run.sh
```

Verify the hub:

```bash
export HUB_KUBECONFIG=$PWD/build/hub-sno/install/auth/kubeconfig
export KUBECONFIG=$HUB_KUBECONFIG

oc get nodes
oc get clusterversion
oc get co
```

Destroy the hub VM and remove the local hub build directory:

```bash
CONFIRM_DELETE_HUB=true ./scripts/hub-delete.sh
```

Recreate the hub after deleting it:

```bash
./scripts/run.sh
```

Force a hub rebuild while keeping the same repo directory:

```bash
FORCE_REBUILD_HUB=true ./scripts/run.sh
```

---

## 3. Create and destroy Site-A and Site-B

Create Site-A:

```bash
./scripts/run-site-a-day2.sh
```

Create Site-B:

```bash
./scripts/run-site-b-day2.sh
```

These site scripts do the hub day-2 work that is needed before bare-metal cluster creation. That includes hub LVM storage, RHACM, Assisted Installer, provisioning services, DNS, iDRAC checks, bare-metal install objects, and the HCP hosting policies for each site.

Verify from the hub:

```bash
export HUB_KUBECONFIG=$PWD/build/hub-sno/install/auth/kubeconfig
export KUBECONFIG=$HUB_KUBECONFIG

oc get managedcluster
oc -n site-a get clusterdeployment,agentclusterinstall,infraenv,bmh,agent -o wide
oc -n site-b get clusterdeployment,agentclusterinstall,infraenv,bmh,agent -o wide
```

Destroy Site-A and Site-B from the hub. Delete HCPs first if they exist:

```bash
./scripts/hcp-delete.sh

CONFIRM_DELETE_SITE_A=true ./scripts/site-a-delete.sh
CONFIRM_DELETE_SITE_B=true ./scripts/site-b-delete.sh
```

The site delete scripts remove RHACM/Assisted Installer objects, the ManagedCluster, policy namespace, ClusterSet, and cluster namespace from the hub. They do **not** wipe bare-metal disks and do **not** clean Pure FlashArray volumes.

---

## 4. Enable Portworx on Site-A and Site-B

Use this after Site-A and Site-B are installed and visible as managed clusters on the hub.

For a clean lab rebuild, first clean old Portworx-created Pure volumes from the FlashArray:

```bash
./scripts/cleanup-pure-portworx-volumes.sh
```

The cleanup script targets only:

```text
pxclouddrive-*
px_*pvc-*
```

It opens one persistent SSH connection to the Pure array, so the Pure password is entered once. It disconnects matching volumes from every Pure host/host group, then destroys and eradicates them where Pure allows it.

Install/apply the Portworx Pure policies:

```bash
./scripts/bootstrap-pure-token-and-portworx.sh
```

That flow creates or refreshes the Pure API token, runs node prep, installs the operator, applies the `px-cluster-flasharray` StorageCluster, enables the console plugin, and applies the HCP StorageClasses.

Check Portworx:

```bash
./scripts/check-portworx-pure.sh
```

Or manually:

```bash
for site in site-a site-b; do
  K="build/hub-sno/${site}/auth/kubeconfig"
  echo
  echo "### $site"
  oc --kubeconfig "$K" -n portworx get storagecluster
  oc --kubeconfig "$K" -n portworx get pods | egrep 'px-cluster|portworx-api|kvdb|csi|stork|cert-manager' || true
done
```

Expected result:

```text
px-cluster-flasharray   Running
px-cluster-flasharray-* 1/1 Running
portworx-api-*          2/2 Running
px-csi-ext              Running
stork                   Running
```

---

## 5. Create and destroy HCP tenants

Create all four hosted clusters and import them into RHACM:

```bash
./scripts/hcp-create.sh
```

This creates two tenants on each hosting site:

| Site | HostedCluster | RHACM ManagedCluster | Shape | Pod CIDR | Service CIDR |
|---|---|---|---|---|---|
| Site-A | `site-a-hcp-t1-px` | `site-a-hcp-t1-px` | PX tenant, extra FADA disks | `10.144.0.0/14` | `172.32.0.0/16` |
| Site-A | `site-a-hcp-t2-kv` | `site-a-hcp-t2-kv` | KubeVirt tenant, no extra PX disks | `10.148.0.0/14` | `172.33.0.0/16` |
| Site-B | `site-b-hcp-t1-px` | `site-b-hcp-t1-px` | PX tenant, extra FADA disks | `10.152.0.0/14` | `172.34.0.0/16` |
| Site-B | `site-b-hcp-t2-kv` | `site-b-hcp-t2-kv` | KubeVirt tenant, no extra PX disks | `10.156.0.0/14` | `172.35.0.0/16` |

The tenant list is defined in `scripts/lib/hcp-tenants.sh`. RHACM import names intentionally match the HostedCluster names.

Check the HCPs:

```bash
oc --kubeconfig build/hub-sno/site-a/auth/kubeconfig -n clusters get hostedcluster,nodepool
oc --kubeconfig build/hub-sno/site-b/auth/kubeconfig -n clusters get hostedcluster,nodepool
oc --kubeconfig build/hub-sno/install/auth/kubeconfig get managedcluster
```

Exported guest kubeconfigs are written here:

```text
build/hub-sno/hcp-kubeconfigs/site-a-hcp-t1-px.kubeconfig
build/hub-sno/hcp-kubeconfigs/site-a-hcp-t2-kv.kubeconfig
build/hub-sno/hcp-kubeconfigs/site-b-hcp-t1-px.kubeconfig
build/hub-sno/hcp-kubeconfigs/site-b-hcp-t2-kv.kubeconfig
```

Destroy all HCP tenants:

```bash
./scripts/hcp-delete.sh
```

For a lab-only stuck namespace cleanup:

```bash
HCP_FORCE_CLEANUP=true ./scripts/hcp-delete.sh
```

---

## 6. Useful one-command flows

Build hub, Site-A and Site-B in one run:

```bash
./scripts/run-full-hub-and-spoke.sh
```

Reapply only the Portworx StorageCluster policy after editing the template:

```bash
./scripts/replace-portworx-storageclusters.sh
```

Repair Portworx policy bindings if RHACM shows selected clusters as empty:

```bash
./scripts/repair-portworx-policy-bindings.sh
```
