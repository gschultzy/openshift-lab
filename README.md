# OpenShift Hub, Spokes and Hosted Control Planes Lab

This repository is pinned consistently to **OpenShift 4.21.25** for the SNO hub, Site-A, Site-B, and all Hosted Control Plane guests. RHACM uses `release-2.16` with MCE `2.11`.

This repository builds:

- An Ansible bastion.
- A vSphere Single Node OpenShift management hub.
- Red Hat Advanced Cluster Management and Multicluster Engine on the hub.
- A three-node bare-metal OpenShift cluster at Site-A.
- A three-node bare-metal OpenShift cluster at Site-B.
- A dedicated Pure FlashArray and Portworx deployment for each site.
- Hosted Control Plane tenant clusters running on Site-A and Site-B.
- All spoke and HCP tenant clusters imported into RHACM on the hub.

Run all commands from the repository root.

## Architecture

```text
                              Ubuntu 24.04 Bastion
                      Ansible + OpenShift command-line tools
                                        |
                                        v
                              vSphere SNO Hub
                    RHACM + MCE + Assisted Installer
                         Central fleet management
                           /                    \
                          /                      \
                         v                        v
              Site-A OpenShift              Site-B OpenShift
              b10-30 / 31 / 33              b10-34 / 35 / 36
              HCP hosting cluster            HCP hosting cluster
                       |                              |
                       v                              v
             SV16-X90R4-B10-01              SV16-X20R4-B08-13
                  10.23.74.50                     10.23.74.60
             Dedicated Portworx              Dedicated Portworx
                       |                              |
                  +----+----+                    +----+----+
                  |         |                    |         |
                  v         v                    v         v
             HCP tenant  HCP tenant         HCP tenant  HCP tenant
               t1-px      t2-kv               t1-px      t2-kv
```

The **SNO hub** is the central management cluster. It runs RHACM, MCE, and Assisted Installer and manages the two physical spoke clusters and the HCP tenant clusters. The SNO is **management-only for HCP**: the global HCP capability remains enabled, while `hypershift-local-hosting` is disabled so tenant control planes are not scheduled on the SNO.

**Site-A** and **Site-B** are independent OpenShift clusters. They act as the dedicated HCP hosting clusters: the Hosted Control Plane components and KubeVirt worker virtual machines run on these clusters.

Each site uses only its assigned Pure FlashArray:

| Site | OpenShift nodes | Pure FlashArray | Management IP |
|---|---|---|---|
| Site-A | `b10-30`, `b10-31`, `b10-33` | `SV16-X90R4-B10-01` | `< ip address >` |
| Site-B | `b10-34`, `b10-35`, `b10-36` | `SV16-X20R4-B08-13` | `< ip address >` |

Portworx provides the storage classes used by the HCP control-plane data, worker VM root disks, and optional tenant data disks. The HCP tenant clusters are then imported into RHACM so the complete environment can be viewed and managed from the hub.

## Deployment Order

Use this order:

1. Configure `main.yml` and `vault.yml`.
2. Configure your pre-created Ubuntu bastion, provied with your CSC lab invite. 
3. Deploy the SNO hub and both spoke clusters.
4. Deploy the dedicated Portworx/Pure storage at each site.
5. Create and import the HCP tenant clusters.
6. Verify the complete environment from the RHACM hub.

## Clean Rebuild from the Previous Environment

OpenShift cannot be downgraded in place. Do not reuse the existing `build/` directory or resume the previous installation. While the old hub is still reachable, remove the environment in this order:

```bash
./scripts/hcp-delete.sh
# Run this destructive step only when Portworx was installed on the spokes:
CONFIRM_PORTWORX_WIPE=true ./scripts/portworx-uninstall-and-wipe-spokes.sh
CONFIRM_DELETE_SITE_B=true ./scripts/site-b-delete.sh
CONFIRM_DELETE_SITE_A=true ./scripts/site-a-delete.sh
CONFIRM_DELETE_HUB=true ./scripts/hub-delete.sh
```

Then prepare the repository for a clean OpenShift 4.21 build:

```bash
CONFIRM_PREPARE_421_REBUILD=true ./scripts/prepare-clean-4.21-rebuild.sh
```

The preparation script archives remaining generated state and removes repo-local OpenShift binaries. The bastion bootstrap then downloads the exact `4.21.25` versions of `oc` and `openshift-install`. It preserves `main.yml`, the encrypted `vault.yml`, and all repository source files.

The main deployment and HCP scripts also run `assert-release-baseline.sh`. They stop rather than connect to or resume an OpenShift release from another minor version.

## Configuration

### Main configuration: `main.yml`

All non-secret environment configuration is stored in:

```text
inventories/env/group_vars/all/main.yml
```

Edit it before deployment:

```bash
nano inventories/env/group_vars/all/main.yml
```

It contains:

- OpenShift release and cluster names.
- SNO, Site-A, and Site-B networking.
- Gateways, DNS servers, VIPs, VLANs, and MetalLB ranges.
- vCenter, ESXi, datastore, and port-group settings.
- SNO virtual machine sizing and storage.
- Bare-metal node, iDRAC, and boot-MAC information.
- Dedicated Site-A and Site-B Pure FlashArray settings.
- Portworx storage-class configuration.
- HCP tenant names, cluster and service CIDRs, worker sizing, and storage settings.

Display the active environment configuration with:

```bash
./scripts/show-environment-config.sh
```

Do not store passwords, pull secrets, private keys, or array API tokens in `main.yml`.

### Secret configuration: `vault.yml`

All secrets are stored in the encrypted Ansible Vault file:

```text
inventories/env/group_vars/all/vault.yml
```

This includes:

- vCenter and ESXi credentials.
- Windows DNS credentials.
- iDRAC credentials.
- Red Hat pull secret.
- SSH private material where required.
- Site-A Pure FlashArray credentials and API token.
- Site-B Pure FlashArray credentials and API token.
- HCP tenant authentication secrets.

## Create and Manage Ansible Vault

### Create the Vault for the first time

```bash
cp inventories/env/group_vars/all/vault.yml.example \
  inventories/env/group_vars/all/vault.yml

nano inventories/env/group_vars/all/vault.yml
ansible-vault encrypt inventories/env/group_vars/all/vault.yml
```

Replace every required `CHANGE_ME` value before encrypting the file.

### Edit the encrypted Vault

```bash
ansible-vault edit inventories/env/group_vars/all/vault.yml
```

### View the encrypted Vault

```bash
ansible-vault view inventories/env/group_vars/all/vault.yml
```

### Temporarily decrypt the Vault

```bash
ansible-vault decrypt inventories/env/group_vars/all/vault.yml
```

The file is plaintext after this command. Re-encrypt it immediately after editing:

```bash
ansible-vault encrypt inventories/env/group_vars/all/vault.yml
```

### Change the Vault password

```bash
ansible-vault rekey inventories/env/group_vars/all/vault.yml
```

### Use a Vault password file

```bash
install -m 600 /dev/null ~/.ansible-vault-pass
nano ~/.ansible-vault-pass
export ANSIBLE_VAULT_PASSWORD_FILE="$HOME/.ansible-vault-pass"
```

Place only the Vault password on the first line.

Never commit any of the following:

- A decrypted `vault.yml`.
- A Vault password file.
- Generated kubeconfigs.
- The generated `build/` directory.

The repository `.gitignore` excludes these files by default.

## Build the Bastion

Create an Ubuntu 24.04 VM that can reach:

- vCenter and ESXi.
- Windows DNS.
- All iDRAC interfaces.
- The SNO and bare-metal OpenShift networks.
- Both Pure FlashArray management interfaces.
- Required Red Hat and internet repositories.

Bootstrap the bastion:

```bash
chmod +x scripts/*.sh scripts/lib/*.sh
./scripts/bootstrap-ubuntu-24.04.sh
source .venv/bin/activate
```

Activate the environment in every new terminal:

```bash
source .venv/bin/activate
```

Confirm the tools:

```bash
oc version --client
openshift-install version
ansible --version
```

## Deploy the Hub and Spokes

Run the complete physical-cluster deployment:

```bash
./scripts/run-full-hub-and-spoke.sh
```

This automation:

1. Validates the bastion, OpenShift tools, inventory, vSphere, and networks.
2. Creates and validates the SNO DNS records.
3. Builds or resumes the vSphere SNO hub.
4. Installs hub storage, RHACM, MCE, Fleet Virtualization, fine-grained virtualization RBAC, and Assisted Installer.
5. Discovers and validates the Site-A iDRAC NIC and boot MAC details.
6. Deploys Site-A and imports it into RHACM.
7. Applies the Site-A HCP hosting prerequisites and RHACM policies.
8. Discovers and validates the Site-B iDRAC NIC and boot MAC details.
9. Deploys Site-B and imports it into RHACM.
10. Applies the Site-B HCP hosting prerequisites and RHACM policies.
11. Labels Site-A and Site-B for RHACM Fleet Virtualization and MTV integration.

The workflow is resumable. Completed hub and spoke work is skipped where possible.

## Deploy Dedicated Storage

After both spokes are available, you can pre-stage Portworx against each site's assigned Pure FlashArray. This step is optional before `hcp-create.sh`; the HCP workflow now performs the same node preparation, Operator installation, StorageCluster deployment and readiness wait automatically when Portworx is not ready.

### Site-A

```bash
SITE=site-a ./scripts/bootstrap-pure-token-and-portworx.sh
SITE=site-a ./scripts/check-portworx-pure.sh
```

### Site-B

```bash
SITE=site-b ./scripts/bootstrap-pure-token-and-portworx.sh
SITE=site-b ./scripts/check-portworx-pure.sh
```

Each spoke receives only its own array endpoint, API token, secret, Portworx policy, and storage configuration.

Before proceeding to HCP, confirm the required HCP storage classes exist on both sites:

```bash
./scripts/check-hcp-portworx-storage.sh
```

## Deploy Hosted Control Plane Tenants

HCP tenants are defined in:

```text
inventories/env/group_vars/all/main.yml
```

The default layout contains two HCP tenants per site:

| Hosting site | HCP tenant | Purpose |
|---|---|---|
| Site-A | `site-a-hcp-t1-px` | HCP tenant with additional Portworx-backed data disks |
| Site-A | `site-a-hcp-t2-kv` | HCP tenant using KubeVirt worker root storage |
| Site-B | `site-b-hcp-t1-px` | HCP tenant with additional Portworx-backed data disks |
| Site-B | `site-b-hcp-t2-kv` | HCP tenant using KubeVirt worker root storage |

Create all configured HCP tenants and import them into RHACM:

```bash
./scripts/hcp-create.sh
```

The HCP workflow:

1. Confirms Site-A and Site-B are ready to host HCP.
2. Waits for the RHACM-managed HyperShift add-ons and operators.
3. Applies Portworx node preparation and waits for both master MachineConfigPools to finish.
4. Installs the Portworx Operator and each site-specific Pure-backed `StorageCluster` when required.
5. Waits for the Portworx CRD, `StorageCluster` object and `status.phase=Running` on both sites.
6. Applies the required HyperShift, KubeVirt, networking, pull-secret, and storage prerequisites.
7. Creates each `HostedCluster` and `NodePool` on its assigned hosting site.
8. Uses the site-local Portworx storage classes for HCP etcd, worker root disks, and tenant data disks.
9. Configures the shared HTPasswd administrator on every HostedCluster and grants guest `cluster-admin` rights.
10. Waits for the tenant admin kubeconfig secrets, exports them, imports all HCP tenants into RHACM, and labels them for continuous RBAC enforcement.

Exported HCP kubeconfigs are stored under:

```text
build/lab-sno/hcp-kubeconfigs/
```

The shared lab administrator is configured automatically by `run.sh`, `run-full-hub-and-spoke.sh`, and `hcp-create.sh`.
The requested Pod 74 defaults are:

```text
username: admin
password: Password1!
```

To reconcile the account independently without rebuilding any cluster:

```bash
./scripts/configure-lab-admin.sh
```

For a persistent environment, override the defaults in the encrypted Vault file:

```yaml
vault_cluster_admin_username: "admin"
vault_cluster_admin_password: "CHANGE_ME"
```

Delete all HCP tenants when required:

```bash
./scripts/hcp-delete.sh
```


## Shared administrator architecture

The repository uses a hybrid model:

- RHACM Governance continuously enforces the HTPasswd Secret, OAuth provider, and `cluster-admin` binding on `local-cluster`, Site-A, and Site-B.
- HCP OAuth is configured on each hosting-cluster `HostedCluster` resource.
- HCP guest RBAC is applied through the exported system-admin kubeconfig and then continuously enforced after each guest is imported into RHACM.
- The bcrypt htpasswd entry is stored in `Secret/lab-admin-policies/lab-admin-htpasswd-source` on the hub. A password checksum prevents a new random bcrypt salt from forcing OAuth rollouts on every idempotent run.

The default password is intentionally suitable only for this isolated lab.

## Verify the Complete Environment

Load the hub kubeconfig:

```bash
HUB_NAME=$(./scripts/lib/inventory-value.py \
  --file inventories/env/group_vars/all/main.yml cluster_name)

export KUBECONFIG="$PWD/build/$HUB_NAME/install/auth/kubeconfig"

BUILD_ROOT="$PWD/build/$HUB_NAME"
SITE_A_KUBECONFIG="$BUILD_ROOT/site-a/auth/kubeconfig"
SITE_B_KUBECONFIG="$BUILD_ROOT/site-b/auth/kubeconfig"
HCP_KUBECONFIG_DIR="$BUILD_ROOT/hcp-kubeconfigs"
```

### Verify the hub and managed clusters

```bash
oc get nodes
oc get clusterversion
oc get managedcluster
```

Expected RHACM managed clusters include:

- `site-a`
- `site-b`
- `site-a-hcp-t1-px`
- `site-a-hcp-t2-kv`
- `site-b-hcp-t1-px`
- `site-b-hcp-t2-kv`

### Verify the physical spokes

```bash
oc -n site-a get clusterdeployment,agentclusterinstall,infraenv,bmh,agent -o wide
oc -n site-b get clusterdeployment,agentclusterinstall,infraenv,bmh,agent -o wide
```

### Verify Hosted Control Planes

```bash
./scripts/check-hcp-guest-imports.sh
./scripts/check-hcp-portworx-storage.sh
```

Check the HCP objects directly on each hosting cluster:

```bash
oc --kubeconfig "$SITE_A_KUBECONFIG" \
  -n clusters get hostedcluster,nodepool,pvc

oc --kubeconfig "$SITE_B_KUBECONFIG" \
  -n clusters get hostedcluster,nodepool,pvc
```

List the exported tenant kubeconfigs:

```bash
ls -1 "$HCP_KUBECONFIG_DIR"/*.kubeconfig
```

Use a tenant kubeconfig:

```bash
oc --kubeconfig "$HCP_KUBECONFIG_DIR/site-a-hcp-t1-px.kubeconfig" get nodes
```

## Main Commands

Build or resume the SNO hub and reconcile its LVM, RHACM/MCE, and Fleet Virtualization services:

```bash
./scripts/run.sh
```

Deploy the hub and both physical spokes:

```bash
./scripts/run-full-hub-and-spoke.sh
```

Deploy Site-A day-2 configuration:

```bash
./scripts/run-site-a-day2.sh
```

Deploy Site-B day-2 configuration:

```bash
./scripts/run-site-b-day2.sh
```

Create and import all HCP tenants:

```bash
./scripts/hcp-create.sh
```

Both primary runners enable RHACM Fleet Virtualization automatically. They set
`cnv-mtv-integrations=true` and `fine-grained-rbac=true` on the hub
`MultiClusterHub`, then label the physical managed clusters with
`acm/cnv-operator-install=true`. The management SNO and hosted tenant clusters
are not selected.

Troubleshooting information is available in:

```text
docs/troubleshooting.md
```

## Check ACM installation progress

The deployment prints live ACM status while the `MultiClusterHub` is installing.
To inspect it separately from another terminal:

```bash
./scripts/check-acm.sh
```

To resume the Site-A workflow safely:

```bash
./scripts/run-site-a-day2.sh
```
## MCE and HCP Management Topology

The SNO hub runs RHACM and MCE but does not host tenant control planes. The automation keeps global HyperShift enabled, disables `hypershift-local-hosting`, and pre-creates the MCE add-on work namespace before the cleanup workflow begins. Site-A and Site-B retain their own `hypershift-addon` resources and remain the dedicated HCP hosting clusters.

The topology check runs automatically during the full deployment, Site-A and Site-B day-2 workflows, RHACM/MCE integration, and HCP creation. To run it manually:

```bash
export KUBECONFIG="$PWD/build/lab-sno/install/auth/kubeconfig"
./scripts/fix-acm-hypershift-local-hosting.sh
```

### Local sudo authentication

The deployment configures `systemd-resolved` on the Ubuntu bastion and therefore
needs local sudo access. The runner deliberately invalidates any cached terminal
sudo timestamp before testing access. It skips the password prompt only when
actual non-interactive passwordless sudo is available. Otherwise enter the
Ubuntu login/sudo password when prompted; this is separate from the Ansible
Vault password.

For unattended execution, store only the sudo password in a mode `0600` file and
set:

```bash
export ANSIBLE_BECOME_PASSWORD_FILE="$HOME/.openshift-lab-become-password"
```

### ACM says the MultiClusterEngine CRD is not installed yet

`MultiClusterHub` installs MultiCluster Engine asynchronously. The full runner now waits up to
`mce_install_timeout_seconds` for the MCE CRD, MCE operator CSV and
`MultiClusterEngine/multiclusterengine` object before applying HCP topology settings.

The default values are:

```yaml
mce_install_timeout_seconds: 2400
mce_install_poll_seconds: 15
```

Do not delete the SNO or `MultiClusterHub` when this is only an installation delay. The runner
prints the ACM/MCE CSV and warning-event status while it waits.


## Portworx readiness during HCP creation

`hcp-create.sh` no longer assumes that Portworx was installed separately. It applies the site-specific RHACM policies in dependency order:

1. node preparation;
2. MachineConfigPool health;
3. Portworx Operator, Pure secret and StorageCluster;
4. Portworx readiness;
5. HCP StorageClasses and StorageProfiles.

The default Portworx readiness window is:

```yaml
hcp_portworx_wait_timeout_seconds: 3600
hcp_portworx_wait_poll_seconds: 30
```

During the wait, the runner displays whether the CRD and StorageCluster exist and the current StorageCluster phase. On timeout it prints OLM resources, Portworx pods, CRDs, StorageCluster details and recent events.

## HyperShift add-on readiness

The HyperShift Operator on Site-A and Site-B is installed by the RHACM/MCE
`hypershift-addon`. `hcp-create.sh` waits for all of the following before it
creates tenant clusters:

- the managed add-on reports `Available=True`;
- its deploy `ManifestWork` applies successfully;
- the `HostedCluster` and `NodePool` CRDs exist on the hosting cluster; and
- `deployment/operator` in the `hypershift` namespace has an available replica.

The runner does not use `hcp install render` as a fallback. The Red Hat `hcp`
binary shipped by the environment is used for hosted-cluster lifecycle and
kubeconfig export after the hub-managed add-on has installed the operator.

### ACM 2.16 virtualization add-on names

ACM 2.16 uses two Fleet Virtualization add-ons: `mtv-operator` and
`kubevirt-hyperconverged`. The older ACM 2.15
`kubevirt-hyperconverged-operator` add-on was merged into
`kubevirt-hyperconverged` and must not be included in readiness waits. The
virtualization playbook removes that obsolete object when it is found, labels
existing Site-A and Site-B ManagedClusters, and prints live diagnostics while
waiting for the two ACM 2.16 add-ons.

## Kubernetes NMState on Site-A and Site-B

The full hub-and-spoke workflow installs the Kubernetes NMState Operator only on
the physical HCP hosting clusters:

- `site-a`
- `site-b`

It does not install NMState on the management SNO (`local-cluster`) or on the
hosted tenant clusters. NMState configures the node interfaces of the cluster
where it runs, so the physical hosting clusters are the correct scope for Linux
bridges, bonds, VLANs, secondary NICs, routes, and later
`NodeNetworkConfigurationPolicy` resources.

NMState is enforced by the existing Site-A and Site-B RHACM Governance policy
bundles. Each bundle creates:

- `Namespace/openshift-nmstate`
- `OperatorGroup/openshift-nmstate`
- `Subscription/kubernetes-nmstate-operator` on channel `stable`
- the singleton `NMState/nmstate`

A full deployment installs and validates NMState automatically:

```bash
./scripts/run-full-hub-and-spoke.sh
```

To reconcile NMState on an environment where Site-A and Site-B already exist:

```bash
./scripts/install-nmstate-hosting-clusters.sh
```

The wait verifies that `NMState/nmstate` is `Available` and that every physical
node has a `NodeNetworkState` object. Configuration of the primary interface,
its underlying interface, or `br-ex` is intentionally not included. Add network
policies only after identifying the correct secondary interfaces.
