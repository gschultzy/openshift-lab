# SNO VMware fixes for this lab

This repo version is fixed for the current environment VMware SNO hub design.

## SNO networking

The SNO hub VM uses one NIC only:

```yaml
sno_node:
  primary_interface: ens192
  secondary_nic_enabled: false
  mac_eth1: ""
  secondary_interface: ""

vm_network_eth0: "{{ discovered_port_group_name }}"
vm_network_eth1: ""
```

Do not attach VLAN {{ secondary_vlan_id }} to the SNO hub. VLAN {{ secondary_vlan_id }} can be used later for other lab hosts or workloads, but the hub itself only needs the {{ vm_network_eth0 }} machine network.

## vSphere disk UUID

The VM creation playbook enforces:

```text
disk.EnableUUID = TRUE
```

This is done with `scripts/set-vm-advanced-setting.py` through pyVmomi after the VM is created or updated.

## Clean rebuild after changing NIC config

If an earlier Agent ISO was generated with two NICs, remove the old build state and regenerate:

```bash
rm -rf build/{{ cluster_name }}
ansible-playbook -i inventories/env/hosts.yml playbooks/01_render_agent_iso.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/02_create_vsphere_vm.yml --ask-vault-pass
```

For a full VM recreate, set:

```yaml
sno_vm_recreate: true
```

Then run `02_create_vsphere_vm.yml`. Set the value back to `false` afterwards.

## Port group creation on distributed switches

If vCenter discovery shows only the port group selected by `vm_network_eth0` and a distributed switch uplink object such as
`{{ discovered vSphere uplink }}`, the ESXi host is probably using a vSphere Distributed Switch
rather than a standard `vSwitch0`. In that case, keep:

```yaml
vm_network_eth0: "{{ discovered_port_group_name }}"
vm_network_eth1: ""
sno_primary_portgroup_auto_create: false
sno_primary_portgroup_create_mode: auto
sno_primary_dvs_name: "{{ discovered_dvs_name }}"
sno_primary_portgroup_vlan_id: 0
```

Use VLAN ID `0` when the ESXi physical uplink is on an access switchport for VLAN {{ machine_vlan_id }}.
Use VLAN ID `3574` only when the uplink is trunking tagged VLAN {{ machine_vlan_id }}.

The VM creation playbook will first try a standard vSwitch. If `vSwitch0` is not present,
it will create the `{{ vm_network_eth0 }}` distributed port group on the configured DVS through vCenter.


## Second 800 GB disk

The SNO VM definition includes a second 800 GB thin disk for later use:

```yaml
sno_vm_extra_disk_enabled: true
sno_vm_extra_disk_gb: 800
sno_vm_extra_disk_type: thin
```

The playbook attaches the disk only. It does not create a filesystem, StorageClass, or mount inside RHCOS/OpenShift.

## Automatic Agent ISO disconnect

Agent ISO installs need the VM to boot from CD-ROM for the first boot only. After RHCOS is written to disk, the VM must boot from disk. The wait playbook monitors `.openshift_install.log` and disconnects the CD-ROM when it sees `Writing image to disk: 100%`, then sets the boot order to disk first.

```yaml
sno_auto_disconnect_iso_after_disk_write: true
sno_set_boot_disk_first_after_iso_disconnect: true
```

A standalone helper is also available:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/03_disconnect_agent_iso.yml --ask-vault-pass
```

## 2026-06-26 update: ISO boot loop prevention and second disk

The VM is now configured with **disk-first, CD-ROM-fallback** boot order. On first boot, the empty disk is skipped and the Agent ISO boots. After RHCOS writes the disk and reboots, the VM should boot from disk instead of returning to the Agent ISO.

`03_wait_install.yml` still attempts a best-effort CD-ROM disconnect after `Writing image to disk: 100%`, but the disconnect is no longer fatal. Some vSphere configurations expose the CD-ROM as `ide0:0`, which cannot be hot-disconnected while powered on and returns `Connection control operation failed for disk 'ide0:0'`.

The SNO VM definition includes an optional second 800GB thin disk. For a running VM after install, use:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/02_add_sno_extra_disk.yml --ask-vault-pass
```

The extra VMDK is only attached. It is not formatted, mounted, or claimed by OpenShift automatically.
