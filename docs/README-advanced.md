# OCP SNO VMware Hub + ACM Bare-Metal Spoke - Ansible Starter

## SNO networking update: one NIC only

The VMware SNO hub is now configured for a single VM NIC by default. Only `vm_network_eth0` is required, and it should point at the vSphere port group that carries VLAN {{ machine_vlan_id }} / the machine network. The optional secondary NIC is disabled with `sno_node.secondary_nic_enabled: false`, and `vm_network_eth1` can remain blank.

```yaml
sno_node:
  primary_interface: ens192
  secondary_nic_enabled: false

vm_network_eth0: "{{ discovered_port_group_name }}"
vm_network_eth1: ""
```

If your vCenter discovery only shows the port group selected by `vm_network_eth0`, and the port group selected by `vm_network_eth0` is actually the access network for VLAN {{ machine_vlan_id }} in this lab, set `vm_network_eth0: "{{ discovered_port_group_name }}"`. Do not use `{{ discovered vSphere uplink }}` for the SNO VM unless it is intentionally configured as a VM workload port group.


This repo bootstraps a Single Node OpenShift (SNO) cluster on VMware vSphere using the OpenShift Agent-based Installer, installs Red Hat Advanced Cluster Management (ACM) on that SNO hub, then uses ACM / multicluster engine / Assisted Installer to build a managed bare-metal OpenShift cluster from Dell PowerEdge nodes.

The pattern is:

1. Render `install-config.yaml` and `agent-config.yaml` from Ansible variables.
2. Generate an OpenShift `agent.iso` that contains the static network configuration for the SNO hub.
3. Upload the ISO to a vSphere datastore.
4. Create a vSphere VM with one NIC:
   - `eth0` / `ens192` on the VLAN {{ machine_vlan_id }} machine-network port group
5. Attach the ISO, boot the VM, and wait for the OpenShift SNO install to complete.
6. Install ACM on the SNO hub.
7. Configure Assisted Service storage on the hub.
8. Render and apply the bare-metal spoke cluster resources:
   - `ManagedCluster`
   - `KlusterletAddonConfig`
   - `ClusterDeployment`
   - `AgentClusterInstall`
   - `InfraEnv`
   - `NMStateConfig`
   - `BareMetalHost`
   - BMC and pull-secret `Secret` objects
9. Boot the Dell nodes through iDRAC Redfish virtual media and let ACM deploy the managed cluster.
10. Optionally configure AD DNS records for both clusters.

> Do not commit real credentials, pull secrets, kubeconfigs, or generated install state to GitHub.

---

## Hub and spoke design

```text
VMware / vSphere
  └── {{ cluster_name }} VM
        └── OpenShift SNO
              └── ACM + multicluster engine + Assisted Service
                    └── bm-spoke-01 bare-metal OpenShift cluster
                          ├── {{ bm_nodes[0].name }} master
                          ├── {{ bm_nodes[1].name }} master
                          ├── {{ bm_nodes[2].name }} master
                          ├── {{ site_b_nodes[0].name }} worker
                          ├── {{ site_b_nodes[1].name }} worker
                          └── {{ site_b_nodes[2].name }} worker
```

See [`docs/hub-spoke-architecture.md`](docs/hub-spoke-architecture.md) for the full IP and BMC plan.

## Lab assumptions

These values are based on the provided environment lab details and should be adjusted in `inventories/env/group_vars/all/main.yml`.

| Item | Example |
|---|---|
| vCenter | `{{ vcenter_hostname }}` |
| ESXi host | `{{ vsphere_esxi_hostname }}` |
| Ansible controller / bastion | `{{ bastion_ip }}` / Ubuntu 24.04.4 LTS |
| AD DNS | `{{ ad_dns_server }}` |
| Base domain | `{{ base_domain }}` |
| Cluster name | `{{ cluster_name }}` |
| SNO node IP | `{{ sno_node.ip }}` |
| API DNS target | `{{ sno_node.ip }}` by default for SNO platform `none` |
| Ingress DNS target | `{{ sno_node.ip }}` by default for SNO platform `none` |
| Reserved API VIP | `{{ api_vip }}`, only used if `sno_install_platform: vsphere` |
| Reserved Ingress VIP | `{{ ingress_vip }}`, only used if `sno_install_platform: vsphere` |
| Gateway | `{{ gateway }}` |
| Machine network | `{{ machine_cidr }}` |
| DNS server | `{{ ad_dns_server }}` |
| VLAN {{ machine_vlan_id }} port group | `{{ vm_network_eth0 }}` |
| Bare-metal cluster | `bm-spoke-01` |
| Bare-metal API VIP | `{{ bm_api_vip }}` |
| Bare-metal Ingress VIP | `{{ bm_ingress_vip }}` |

DNS records expected:

```text
api.{{ cluster_name }}.{{ base_domain }}       -> {{ sno_node.ip }}
api-int.{{ cluster_name }}.{{ base_domain }}   -> {{ sno_node.ip }}
*.apps.{{ cluster_name }}.{{ base_domain }}    -> {{ sno_node.ip }}
{{ cluster_name }}-0.{{ cluster_name }}.{{ base_domain }} -> {{ sno_node.ip }}
```


## SNO install platform mode

The default SNO install platform is:

```yaml
sno_install_platform: none
```

This is intentional for this lab. Ansible creates the VM on the standalone ESXi host through vCenter, while the OpenShift Agent ISO installs SNO with a static IP. In this mode, the hub API and apps wildcard DNS records point directly to the SNO node IP, `{{ sno_node.ip }}`.

The reserved `api_vip` and `ingress_vip` values are only used if you deliberately switch the install config to vSphere platform mode:

```yaml
sno_install_platform: vsphere
vsphere_cluster: "YOUR_VCENTER_CLUSTER_NAME"
```

Do not set `sno_install_platform: vsphere` unless your vCenter inventory has a real compute cluster name and you want OpenShift to be vSphere platform-integrated. For the provided environment layout, leave it as `none`.

---

## Prerequisites on the Ubuntu 24.04.4 LTS bastion

The Ansible controller for this lab is the Ubuntu bastion VM:

| Item | Value |
|---|---|
| Bastion VM | `{{ bastion_hostname }}` |
| Bastion IP | `{{ bastion_ip }}` |
| OS | Ubuntu 24.04.4 LTS |
| Role | Ansible control node, OpenShift installer host, vSphere automation runner |

Use the included bootstrap script from the Ubuntu bastion:

```bash
cd /path/to/openshift-lab
./scripts/bootstrap-ubuntu-24.04.sh
source .venv/bin/activate
```

The script reads the exact OpenShift client and installer release from
`ocp_release_version` in `inventories/env/group_vars/all/main.yml` (currently `4.21.25`). Keep the
release pin in that inventory rather than duplicating it in bootstrap commands.

The bootstrap installs the Ubuntu packages, creates a Python virtual environment, installs the Python module requirements, installs the Ansible Galaxy collections, installs or wraps `nmstatectl`, and places `oc`, `kubectl`, and `openshift-install` in `/usr/local/bin`.

`nmstatectl` is required for this static-IP Agent ISO flow. The OpenShift installer validates the `networkConfig` section in `agent-config.yaml` by calling `nmstatectl` locally before it creates the ISO. If `nmstatectl` is missing, ISO generation fails before the VM is created.

Validate the bastion before running the cluster automation:

```bash
source .venv/bin/activate
oc version --client
kubectl version --client
openshift-install version
nmstatectl --version || nmstatectl -h | head -1
ansible --version
ansible-galaxy collection list | egrep 'community.vmware|ansible.windows|ansible.utils'
```

The Ubuntu-specific requirements are split into two files:

```text
requirements-python.txt   # Python packages installed into .venv
requirements.yml          # Ansible Galaxy collections
```

See [`docs/ubuntu-bastion.md`](docs/ubuntu-bastion.md) for the full Ubuntu package list, venv setup, proxy notes, and validation steps. See [`docs/vsphere-iso-upload.md`](docs/vsphere-iso-upload.md) for the ISO upload options.

---

## Configure variables

Ansible variable layout used by this repo:

```text
inventories/env/group_vars/all/main.yml   # normal, non-secret variables
inventories/env/group_vars/all/vault.yml  # encrypted secrets only
```

Edit:

```bash
inventories/env/group_vars/all/main.yml
```

Create your private vault file from the example:

```bash
source .venv/bin/activate
cp inventories/env/group_vars/all/vault.yml.example inventories/env/group_vars/all/vault.yml
ansible-vault encrypt inventories/env/group_vars/all/vault.yml
ansible-vault edit inventories/env/group_vars/all/vault.yml
```

Put your real vCenter password, pull secret, and SSH public key in the encrypted vault file.

---

## Troubleshooting: `nmstatectl` missing during ISO creation

If `playbooks/01_render_agent_iso.yml` fails with:

```text
failed to validate network yaml ... exec: "nmstatectl": executable file not found in $PATH
```

run the repo helper from the active virtual environment:

```bash
cd /path/to/openshift-lab
source .venv/bin/activate
./scripts/install-nmstatectl-ubuntu.sh
command -v nmstatectl
nmstatectl --version || nmstatectl -h | head -1
```

On Ubuntu 24.04/Noble, an apt package named `nmstate` might not exist in the enabled repositories. The helper therefore installs Ubuntu's packaged `python3-gi` runtime, installs the `nmstate` Python package with `--no-deps`, and wraps `.venv/bin/nmstatectl` so it can import `/usr/lib/python3/dist-packages`.

If you previously hit this PyGObject error:

```text
Dependency 'girepository-2.0' is required but not found
```

do not keep retrying `pip install nmstate==2.0.0` normally. That causes pip to build the newest PyGObject from PyPI. Use the helper instead.

Then rerun:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/01_render_agent_iso.yml --ask-vault-pass
```

---


## Troubleshooting: vCenter datastore folder creation returns 404

If `playbooks/02_create_vsphere_vm.yml` fails while creating the ISO folder with an error like:

```text
Failed to create temporary file
url: https://{{ vcenter }}/folder/iso/foobar.tmp?dsName={{ vsphere_datastore }}&dcPath=Datacenter
status: 404
reason: Not Found
```

use the default ESXi SSH/SCP upload mode instead of the vCenter datastore HTTP API. This repo now defaults to:

```yaml
iso_upload_method: esxi_ssh
esxi_hostname: "{{ vsphere_esxi_hostname }}"
esxi_username: root
esxi_password: "{{ vault_esxi_password }}"
esxi_datastore_mount: "/vmfs/volumes/{{ vsphere_datastore }}"
```

Add the ESXi root password to your encrypted vault file:

```bash
ansible-vault edit inventories/env/group_vars/all/vault.yml
```

Example vault entry:

```yaml
vault_esxi_password: "CHANGE_ME"
```

Make sure SSH is enabled on the ESXi host, then rerun:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/02_create_vsphere_vm.yml --ask-vault-pass
```

The ISO will be copied directly to the ESXi datastore path, for example:

```text
/vmfs/volumes/{{ vsphere_datastore }}/iso/ocp/{{ cluster_name }}-agent.x86_64.iso
```

The VM still references it through vCenter as:

```text
[{{ vsphere_datastore }}] iso/ocp/{{ cluster_name }}-agent.x86_64.iso
```

To force the old vCenter API upload method, set:

```yaml
iso_upload_method: vcenter_api
```

---


## Important fix in this package: single-NIC SNO + disk.EnableUUID

This package has the VMware SNO hub fixed for your current design:

```yaml
sno_node:
  primary_interface: ens192
  secondary_nic_enabled: false
  mac_eth1: ""
  secondary_interface: ""

vm_network_eth0: "{{ discovered_port_group_name }}"
vm_network_eth1: ""

sno_vm_disk_enable_uuid: true
sno_vm_poweroff_before_configure: true
sno_vm_recreate: false
```

The SNO VM has one NIC only. It does not require VLAN {{ secondary_vlan_id }}. The VM creation playbook also enforces the required vSphere advanced setting:

```text
disk.EnableUUID = TRUE
```

If you already generated an ISO before this fix, remove the old build directory and regenerate the ISO so the embedded AgentConfig no longer includes `ens224`:

```bash
cd /path/to/openshift-lab
source .venv/bin/activate
rm -rf build/{{ cluster_name }}
ansible-playbook -i inventories/env/hosts.yml playbooks/01_render_agent_iso.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/02_create_vsphere_vm.yml --ask-vault-pass
```

If you want the playbook to delete and recreate the existing `{{ cluster_name }}` VM, temporarily set this in `inventories/env/group_vars/all/main.yml`:

```yaml
sno_vm_recreate: true
```

Set it back to `false` after the clean VM has been created.

This repo also adds a second 800 GB thin disk to the SNO VM for later use:

```yaml
sno_vm_extra_disk_enabled: true
sno_vm_extra_disk_gb: 800
sno_vm_extra_disk_type: thin
```

The second disk is only attached to the VM. It is not formatted or mounted automatically inside RHCOS/OpenShift.

`03_wait_install.yml` also watches the installer log and disconnects the Agent ISO after the RHCOS image has been written to disk, then changes the VM boot order to disk-first. This prevents the VM from rebooting back into the Agent ISO.

```yaml
sno_auto_disconnect_iso_after_disk_write: true
sno_set_boot_disk_first_after_iso_disconnect: true
```

## Run the SNO hub build

Run all commands from the Ubuntu bastion with the repo virtual environment active:

```bash
source .venv/bin/activate
```

Then run:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/00_preflight.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/04_configure_ad_dns.yml --ask-vault-pass --ask-become-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/01_render_agent_iso.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/02_create_vsphere_vm.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/03_wait_install.yml --ask-vault-pass
```

Or run the SNO-only flow:

```bash
./scripts/run.sh
```

## Install ACM on the SNO hub

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/06_install_acm.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/07_configure_assisted_service.yml --ask-vault-pass
```

The ACM channel is controlled by this variable:

```yaml
acm_subscription_channel: release-2.16
```

Check available channels on your hub with:

```bash
oc get packagemanifest advanced-cluster-management -n openshift-marketplace \
  -o jsonpath='{.status.channels[*].name}'
```

## Build the ACM managed bare-metal cluster

First, confirm the missing boot MACs for `{{ site_b_nodes[1].name }}` and `{{ site_b_nodes[2].name }}` in:

```bash
inventories/env/group_vars/all/main.yml
```

Then run:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/10_configure_bm_ad_dns.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/05_idrac_preflight.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/08_apply_baremetal_cluster.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/09_wait_baremetal_cluster.yml --ask-vault-pass
```

Or run the full hub-and-spoke flow:

```bash
./scripts/run-full-hub-and-spoke.sh
```

---

## Optional AD DNS setup

If WinRM is enabled to the AD server, you can run:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/04_configure_ad_dns.yml --ask-vault-pass --ask-become-pass
```

If WinRM is not enabled, create these records manually in AD DNS:

```powershell
Add-DnsServerResourceRecordA -ZoneName "{{ base_domain }}" -Name "api.{{ cluster_name }}" -IPv4Address "{{ sno_node.ip }}"
Add-DnsServerResourceRecordA -ZoneName "{{ base_domain }}" -Name "api-int.{{ cluster_name }}" -IPv4Address "{{ sno_node.ip }}"
Add-DnsServerResourceRecordA -ZoneName "{{ base_domain }}" -Name "*.apps.{{ cluster_name }}" -IPv4Address "{{ sno_node.ip }}"
Add-DnsServerResourceRecordA -ZoneName "{{ base_domain }}" -Name "{{ cluster_name }}-0.{{ cluster_name }}" -IPv4Address "{{ sno_node.ip }}"
```

---

## Bare-metal cluster defaults

The default spoke cluster uses the Dell nodes like this:

| Node | iDRAC IP | OpenShift IP | Role | Status |
|---|---:|---:|---|---|
| {{ bm_nodes[0].name }} | {{ bm_nodes[0].bmc_ip }} | {{ bm_nodes[0].ip }} | master | ready |
| {{ bm_nodes[1].name }} | {{ bm_nodes[1].bmc_ip }} | {{ bm_nodes[1].ip }} | master | ready |
| {{ bm_nodes[2].name }} | {{ bm_nodes[2].bmc_ip }} | {{ bm_nodes[2].ip }} | master | ready |
| {{ site_b_nodes[0].name }} | {{ site_b_nodes[0].bmc_ip }} | {{ site_b_nodes[0].ip }} | worker | ready |
| {{ site_b_nodes[1].name }} | {{ site_b_nodes[1].bmc_ip }} | {{ site_b_nodes[1].ip }} | worker | needs boot MAC |
| {{ site_b_nodes[2].name }} | {{ site_b_nodes[2].bmc_ip }} | {{ site_b_nodes[2].ip }} | worker | needs boot MAC |

The `{{ BMC addresses from bm_nodes/site_b_nodes }}` addresses are treated as BMC/iDRAC IPs, not OpenShift node IPs.

The default BMC URL format is:

```text
redfish-virtualmedia://{{ idrac-ip }}/redfish/v1/Systems/System.Embedded.1
```

This is required for this no-DHCP/no-provisioning-network style of automation.

## Switching to a 3-node compact cluster

For a smaller demo cluster, keep only the first three nodes enabled:

```yaml
bm_control_plane_count: 3
bm_worker_count: 0

# {{ site_b_nodes[0].name }}, {{ site_b_nodes[1].name }}, {{ site_b_nodes[2].name }}
enabled: false
```

## Validation

After the SNO hub install finishes:

```bash
export KUBECONFIG="$PWD/build/{{ cluster_name }}/auth/kubeconfig"
oc get nodes
oc get clusterversion
oc get co
oc get route console -n openshift-console
```

After the bare-metal cluster is created from ACM:

```bash
oc get managedcluster
oc -n bm-spoke-01 get clusterdeployment,agentclusterinstall,infraenv
oc -n bm-spoke-01 get bmh,agents -o wide
```

Console URL:

```text
https://console-openshift-console.apps.{{ cluster_name }}.{{ base_domain }}
```

---

## Important notes

- DHCP is not used. Static IP is embedded in `agent-config.yaml`.
- The SNO VM NIC MAC addresses must match the MAC addresses in `agent-config.yaml`.
- The VMware port group backing `eth0` must be an access port group for VLAN {{ machine_vlan_id }}.
- With the default `sno_install_platform: none`, `apiVIPs` and `ingressVIPs` are not rendered into `install-config.yaml`; API and apps DNS point to the SNO node IP.
- If you switch to `sno_install_platform: vsphere`, `apiVIPs`, `ingressVIPs`, and `vsphere_cluster` must be valid for your vCenter inventory.
- The VMware playbook defaults to the standalone ESXi host at `{{ vsphere_esxi_hostname }}`; if your vCenter inventory uses a cluster, edit `02_create_vsphere_vm.yml` to use `cluster` instead of `esxi_hostname`.
- For this SNO hub lab, reusing the SNO node IP for API and apps DNS is expected in platform `none` mode.
- `.local` can conflict with mDNS in some environments. It is okay for a controlled lab, but a normal DNS zone is cleaner.
- The ACM bare-metal flow assumes Redfish virtual media because DHCP and a provisioning network are not being used.
- The {{ site_b_nodes[1].name }} and {{ site_b_nodes[2].name }} boot NIC MAC addresses are placeholders and must be filled in before running `08_apply_baremetal_cluster.yml`.
- The starter enforces iDRAC firmware consistency and currently expects `{{ older iDRAC firmware release }}`. Update `idrac_firmware_expected` if you standardise on a different version.



## Troubleshooting: `community.general.yaml` callback removed

If you see this error on Ubuntu 24.04 after installing the latest Ansible collections:

```text
[ERROR]: The 'community.general.yaml' callback plugin has been removed.
```

Use the updated `ansible.cfg` included in this repo. The old setting was:

```ini
stdout_callback = yaml
```

The new supported setting is:

```ini
stdout_callback = ansible.builtin.default
callback_result_format = yaml
```

This keeps readable YAML-like playbook output without depending on the removed `community.general.yaml` callback plugin.

To verify what Ansible is actually loading:

```bash
ansible-config dump --only-changed | egrep 'DEFAULT_STDOUT_CALLBACK|CALLBACK_RESULT_FORMAT|CONFIG_FILE'
```

You should see the repo-local `ansible.cfg` and the built-in default callback.

## Troubleshooting: `ipaddr` conditional must be boolean

If preflight fails with this message:

```text
Conditional result (True) was derived from value of type 'str'. Conditionals must have a boolean result.
```

The issue is caused by using the return value from `ansible.utils.ipaddr` directly in an `assert`. The filter returns the matching IP string when the address is valid, but newer Ansible versions require conditionals to evaluate to a real boolean.

The fixed preflight uses explicit boolean comparisons:

```yaml
- "(sno_node.ip | ansible.utils.ipaddr(machine_cidr)) != false"
- "(sno_api_ip | ansible.utils.ipaddr(machine_cidr)) != false"
- "(sno_ingress_ip | ansible.utils.ipaddr(machine_cidr)) != false"
```

Then rerun:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/00_preflight.yml --ask-vault-pass
```

## Troubleshooting: `vault_vcenter_password is undefined`

The vault file must be in the `all` group vars directory so Ansible loads it automatically:

```bash
inventories/env/group_vars/all/vault.yml
```

If you created it in the old starter location:

```bash
inventories/env/group_vars/vault.yml
```

move it with:

```bash
./scripts/fix-vault-location.sh
```

Or do it manually:

```bash
mkdir -p inventories/env/group_vars/all
mv inventories/env/group_vars/vault.yml inventories/env/group_vars/all/vault.yml
```

Then verify that Ansible can see the vaulted variables:

```bash
ansible-inventory -i inventories/env/hosts.yml --list --ask-vault-pass \
  | jq '._meta.hostvars.localhost | has("vault_vcenter_password")'
```

It should return:

```text
true
```



## Troubleshooting: `vsphere_cluster is undefined` during ISO render

Older versions of this starter always rendered a vSphere platform block in `install-config.yaml`, which required this variable:

```yaml
vsphere_cluster: "..."
```

That is not ideal for the provided environment lab because the VM is being created by Ansible on a standalone ESXi host through vCenter. The current default is now:

```yaml
sno_install_platform: none
```

With that setting, the rendered `install-config.yaml` contains:

```yaml
platform:
  none: {}
```

and no longer needs `vsphere_cluster`. If you really want a vSphere-integrated install, set `sno_install_platform: vsphere` and provide a real vCenter compute cluster name in `vsphere_cluster`.


### Ubuntu 24.04 nmstatectl note

Ubuntu 24.04 may not have a native `nmstate` package. The repo helper therefore installs a local `nmstatectl` shim for the simple static Ethernet SNO config generated by this lab:

```bash
./scripts/install-nmstatectl-ubuntu.sh
command -v nmstatectl
nmstatectl --version
```

Set `USE_NMSTATECTL_AGENT_SHIM=false` if you want the helper to fail instead of installing the shim. For complex NMState configs such as bonds, VLANs, or bridges, use a RHEL/Rocky bastion and install the real package with `dnf install nmstate`.


## vSphere datastore ISO folder troubleshooting

If `playbooks/02_create_vsphere_vm.yml` fails with a message similar to:

```text
Failed to create temporary file
url: https://{{ vcenter }}/folder/iso/ocp/foobar.tmp?dsName={{ vsphere_datastore }}&dcPath=Datacenter
status: 404
reason: Not Found
```

then the datastore browser cannot find or create the target folder path. The playbook now creates the folder path one level at a time, for example `iso` first and then `iso/ocp`.

First confirm the datastore and datacenter names match the vCenter inventory exactly:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/00_preflight.yml --ask-vault-pass
```

If folder creation is still blocked, upload the ISO to the datastore root by changing:

```yaml
iso_datastore_folder: ""
```

Then rerun:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/02_create_vsphere_vm.yml --ask-vault-pass
```

When using the datastore root fallback, the VM CD-ROM path becomes:

```text
[{{ vsphere_datastore }}] {{ cluster_name }}-agent.x86_64.iso
```

## Troubleshooting: `No datacenter named Datacenter was found`

If `playbooks/02_create_vsphere_vm.yml` fails at VM creation with:

```text
No datacenter named Datacenter was found
```

then the placeholder value in `inventories/env/group_vars/all/main.yml` does not match the exact vCenter inventory name.

Run the discovery playbook:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/00_discover_vsphere_inventory.yml --ask-vault-pass
```

Then update these values exactly as shown by vCenter:

```yaml
vsphere_datacenter: "{{ exact datacenter name }}"
vsphere_folder: "/{{ vsphere_datacenter }}/vm"
vsphere_esxi_hostname: "{{ exact host name from vCenter, often an FQDN rather than an IP }}"
vsphere_datastore: "{{ exact datastore name }}"
vm_network_eth0: "{{ exact port group for VLAN <machine_vlan_id }}>"
vm_network_eth1: ""  # not used unless secondary_nic_enabled is true
```

The playbooks now include early vSphere inventory validation so the error shows the available datacenter names before it reaches the VM creation task.
## SNO hub networking: one NIC only

The VMware SNO hub uses one vSphere NIC by default:

```text
{{ cluster_name }} ens192 -> vm_network_eth0 -> {{ vm_network_eth0 }} / machine network
```

`vm_network_eth1` is intentionally blank and `sno_node.secondary_nic_enabled` is `false`.

Discovery must show the primary port group before VM creation succeeds:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/00_discover_vsphere_inventory.yml --ask-vault-pass
```

If discovery only shows the port group selected by `vm_network_eth0` and `{{ discovered vSphere uplink }}`, either set `vm_network_eth0: "{{ discovered_port_group_name }}"` if MGMT is already backed by VLAN {{ machine_vlan_id }}, or create a dedicated port group:

```yaml
vm_network_eth0: "{{ discovered_port_group_name }}"
vm_network_eth1: ""
esxi_vswitch_name: vSwitch0
sno_primary_portgroup_vlan_id: 0
```

Use `sno_primary_portgroup_vlan_id: 0` when the ESXi physical switchport is an access port on VLAN {{ machine_vlan_id }}. Use `3574` only when the ESXi uplink is trunked and tagging VLAN {{ machine_vlan_id }} is required on the port group.

To create/validate the standard vSwitch port group over ESXi SSH:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/00_create_sno_primary_portgroup.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/00_discover_vsphere_inventory.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/02_create_vsphere_vm.yml --ask-vault-pass
```


## Troubleshooting a stalled Agent install wait

`playbooks/03_wait_install.yml` runs `openshift-install agent wait-for bootstrap-complete` and then `install-complete`. These commands can look quiet in Ansible because output is buffered. If it appears stalled, interrupt only the waiter with `Ctrl+C`; the OpenShift installation continues on the VM.

Run the diagnostic playbook:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/03_check_install_status.yml --ask-vault-pass
```

It checks VM power state, DNS resolution, ping to the SNO static IP, ports 22/6443/22623, the installer log, and basic RHCOS/agent journal snippets over SSH.

For the SNO hub using `platform: none`, make sure these DNS records resolve to the SNO node IP:

```text
api.{{ cluster }}.{{ base-domain }}       -> SNO node IP
api-int.{{ cluster }}.{{ base-domain }}   -> SNO node IP
*.apps.{{ cluster }}.{{ base-domain }}    -> SNO node IP
```



### ESXi SCP upload fails on Ubuntu 24.04

Ubuntu 24.04 uses a newer OpenSSH `scp` that defaults to SFTP mode. Many ESXi hosts do not provide an SFTP subsystem, so a plain `scp` can fail even when SSH and `mkdir` work. The playbook therefore uses `scp -O` to force the legacy SCP protocol:

```bash
scp -O local.iso root@{{ vsphere_esxi_hostname }}:/vmfs/volumes/{{ vsphere_datastore }}/iso/ocp/
```

The ESXi upload tasks are intentionally not hidden by default (`esxi_upload_no_log: false`) so failures show useful stderr. The password is passed via `SSHPASS` environment variable and is not present in the command line.


## SNO primary port group auto-create

The VMware SNO hub uses one NIC only. By default, `vm_network_eth0` is `{{ vm_network_eth0 }}` and `vm_network_eth1` is blank. If vCenter does not already show `{{ vm_network_eth0 }}` as a VM port group, `playbooks/02_create_vsphere_vm.yml` will now try to create it on the ESXi host using SSH before VM creation.

Defaults:

```yaml
vm_network_eth0: "{{ discovered_port_group_name }}"
vm_network_eth1: ""
esxi_vswitch_name: vSwitch0
sno_primary_portgroup_vlan_id: 0
sno_primary_portgroup_auto_create: false
```

Use VLAN ID `0` when the physical ESXi uplink switchport is already access VLAN {{ machine_vlan_id }}. Use VLAN ID `3574` only when the ESXi uplink is a trunk carrying tagged VLAN {{ machine_vlan_id }}.

---

## Day-2: LVM, RHACM, bare-metal provisioning, and Site-A

The repo now includes a Day-2 flow for the hub after `{{ cluster_name }}` is installed:

```bash
cd /path/to/openshift-lab
source .venv/bin/activate
./scripts/run-site-a-day2.sh
```

This flow:

1. Adds a 800 GB second disk to the `{{ cluster_name }}` VM if it is missing.
2. Installs the LVM Storage Operator.
3. Creates an `LVMCluster` using `/dev/sdb` and sets `lvms-vg1` as the default StorageClass.
4. Installs RHACM.
5. Configures Assisted Service storage.
6. Enables/validates bare-metal provisioning.
7. Configures DNS for `site-a`.
8. Adds `{{ bm_nodes[0].name }}`, `{{ bm_nodes[1].name }}`, and `{{ bm_nodes[2].name }}` through iDRAC/Redfish virtual media.
9. Provisions the managed cluster as `site-a` / `Site-A`.

See `docs/site-a-day2.md` for the step-by-step commands and troubleshooting checks.


### Assisted Image Service rootfs preflight

Before applying or rebooting the bare-metal hosts, run:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/07_validate_assisted_image_service.yml --ask-vault-pass
```

This catches the common iDRAC console failure where the node shows `coreos-livepxe-rootfs` and `curl: (22) The requested URL returned error: 503`. The usual cause is that AD DNS for `*.apps.{{ cluster_name }}.{{ base_domain }}` still points at an old VIP instead of the SNO IP `{{ sno_node.ip }}`, or the Assisted Image Service route has no ready endpoints.

## Site-A bare-metal NIC mapping

If a bare-metal node boots but does not receive its static IP, verify both the
hardware MAC and the RHCOS Linux interface name. Dell/iDRAC may show Integrated
NIC 1 Port 1, while RHCOS names the interface `eno33np0`.

Run:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/05_discover_idrac_nics.yml --ask-vault-pass
```

For the current R6525 {{ bm_nodes[0].name }}/{{ bm_nodes[1].name }}/{{ bm_nodes[2].name }} nodes, the repo defaults the primary
bare-metal interface to `eno33np0` and uses the Integrated NIC 1 Port 1 MACs.

If manifests were already applied with the wrong interface name:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/08_reset_site_a_for_nmstate_fix.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/08_apply_baremetal_cluster.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/08_reboot_site_a_nodes.yml --ask-vault-pass
```

## Site-A HCP KubeVirt hosting

After `site-a` is installed and imported into RHACM, you can prepare it as a Hosted Control Plane hosting cluster with OpenShift Virtualization, MCE, MetalLB, and wildcard ingress policies:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/12_apply_site_a_hcp_policies.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/13_wait_site_a_hcp_prereqs.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/14_create_site_a_hcp_kubevirt_cluster.yml --ask-vault-pass
```

See `docs/site-a-hcp-kubevirt.md` for details and validation commands.
