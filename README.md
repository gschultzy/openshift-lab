# OpenShift hub, Site-A, Site-B and HCP lab

This repo builds this lab:

```text
{{ cluster_name }} = vSphere SNO hub with RHACM/MCE/Assisted Installer
{{ bm_cluster_name }} = bare-metal hosting cluster using enabled entries in bm_nodes
{{ site_b_cluster_name }} = bare-metal hosting cluster using enabled entries in site_b_nodes
HCPs = hosted control planes defined by hcp_tenants
```

Site-A and Site-B are **managed spoke / hosting clusters**. Do not install a second local RHACM/MCE hub on Site-A or Site-B. The hub manages them and enables the HyperShift add-on.

Detailed fixes and troubleshooting have been moved to [`docs/troubleshooting.md`](docs/troubleshooting.md).


All environment-specific values are stored in:

```text
inventories/env/group_vars/all/main.yml
```

Shell helpers load that file through `scripts/lib/inventory-env.sh`; the HCP tenant list is loaded from `hcp_tenants` rather than duplicated in shell scripts. To print the current values:

```bash
./scripts/show-environment-config.sh
```

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
vi inventories/env/group_vars/all/main.yml
```

Important defaults in this lab:

```text
Hub API:        {{ hub_api_hostname }}
Site-A API:     api.{{ bm_cluster_name }}.{{ bm_base_domain }}
Site-B API:     api.{{ site_b_cluster_name }}.{{ site_b_base_domain }}
Site-A nodes:   enabled entries in bm_nodes
Site-B nodes:   enabled entries in site_b_nodes
Site-A array:   {{ site_a_pure_flasharray_name }} / {{ site_a_pure_flasharray_mgmt_endpoint }}
Site-B array:   {{ site_b_pure_flasharray_name }} / {{ site_b_pure_flasharray_mgmt_endpoint }}
```

The scripts ask for the Ansible Vault password once and reuse it. You can also provide a vault password file:

```bash
export ANSIBLE_VAULT_PASSWORD_FILE=/path/to/vault-password-file
```

When bastion DNS resolver automation is enabled, the runner requests the Ubuntu user's local sudo password separately from the Ansible Vault password. It validates the sudo credential before starting the DNS playbook and allows up to three attempts, preventing Ansible's confusing duplicate become-password prompt. The password is stored only in a mode `0600` temporary file for the life of the script and deleted on exit. Passwordless sudo is detected automatically. For unattended execution, provide an Ansible become password file; the runner validates that file before using it:

```bash
export ANSIBLE_BECOME_PASSWORD_FILE=/path/to/local-sudo-password-file
```

---

## 2. Create and destroy the hub

Create the SNO hub VM and wait for OpenShift to install:

```bash
./scripts/run.sh
```

Before rendering or booting the Agent ISO, `run.sh` now performs mandatory DNS preparation:

1. Creates or updates the SNO `api`, `api-int`, apps wildcard, and node records on the configured AD DNS server.
2. Installs a persistent `systemd-resolved` route on the Ubuntu bastion for `base_domain`.
3. Verifies every record directly against `ad_dns_server`.
4. Verifies the same records through the normal Ubuntu system resolver used by `openshift-install`.

All DNS servers, domains, record targets, retry values, and resolver settings are stored in `inventories/env/group_vars/all/main.yml`. The install stops before VM creation when DNS is unavailable or returns the wrong address. If an Agent install state already exists, `run.sh` resumes it instead of deleting the build directory and regenerating the ISO. Use `FORCE_REBUILD_HUB=true` only for a deliberate clean rebuild.

Verify the hub:

```bash
export HUB_KUBECONFIG=$PWD/build/{{ cluster_name }}/install/auth/kubeconfig
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
export HUB_KUBECONFIG=$PWD/build/{{ cluster_name }}/install/auth/kubeconfig
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
  K="build/{{ cluster_name }}/${site}/auth/kubeconfig"
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
| Site-A | `site-a-hcp-t1-px` | `site-a-hcp-t1-px` | PX tenant, extra FADA disks | `{{ hcp_tenants[0].cluster_cidr }}` | `{{ hcp_tenants[0].service_cidr }}` |
| Site-A | `site-a-hcp-t2-kv` | `site-a-hcp-t2-kv` | KubeVirt tenant, no extra PX disks | `{{ hcp_tenants[1].cluster_cidr }}` | `{{ hcp_tenants[1].service_cidr }}` |
| Site-B | `site-b-hcp-t1-px` | `site-b-hcp-t1-px` | PX tenant, extra FADA disks | `{{ hcp_tenants[2].cluster_cidr }}` | `{{ hcp_tenants[2].service_cidr }}` |
| Site-B | `site-b-hcp-t2-kv` | `site-b-hcp-t2-kv` | KubeVirt tenant, no extra PX disks | `{{ hcp_tenants[3].cluster_cidr }}` | `{{ hcp_tenants[3].service_cidr }}` |

The tenant list is defined in `scripts/lib/hcp-tenants.sh`. RHACM import names intentionally match the HostedCluster names.

Check the HCPs:

```bash
oc --kubeconfig build/{{ cluster_name }}/site-a/auth/kubeconfig -n clusters get hostedcluster,nodepool
oc --kubeconfig build/{{ cluster_name }}/site-b/auth/kubeconfig -n clusters get hostedcluster,nodepool
oc --kubeconfig build/{{ cluster_name }}/install/auth/kubeconfig get managedcluster
```

Exported guest kubeconfigs are written here:

```text
build/{{ cluster_name }}/hcp-kubeconfigs/site-a-hcp-t1-px.kubeconfig
build/{{ cluster_name }}/hcp-kubeconfigs/site-a-hcp-t2-kv.kubeconfig
build/{{ cluster_name }}/hcp-kubeconfigs/site-b-hcp-t1-px.kubeconfig
build/{{ cluster_name }}/hcp-kubeconfigs/site-b-hcp-t2-kv.kubeconfig
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
