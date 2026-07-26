# Bare-metal NIC mapping for Site-A

For Dell R6525 hosts, do not assume the Linux interface name is `eno1`.
The iDRAC inventory shows hardware ports and MAC addresses, while RHCOS may name
the same port `eno33np0`, `eno34np1`, etc.

For the current b08-33 console, RHCOS displays:

```text
eno33np0:
```

So the Site-A NMStateConfig should use:

```yaml
primary_interface: eno33np0
```

The iDRAC screenshot shows Integrated NIC 1 Port 1 / Partition 1 has MAC:

```text
BC:97:E1:C3:F6:E0
```

That MAC is valid for b08-33. The problem was the interface name, not necessarily
the MAC.

Run discovery:

```bash
ansible-playbook -i inventories/pod22/hosts.yml playbooks/05_discover_idrac_nics.yml --ask-vault-pass
```

Then confirm the rendered NMStateConfig:

```bash
oc -n site-a get nmstateconfig b08-33 -o yaml
```

If Site-A objects were already created with the wrong interface name, reset and
reapply:

```bash
ansible-playbook -i inventories/pod22/hosts.yml playbooks/08_reset_site_a_for_nmstate_fix.yml --ask-vault-pass
ansible-playbook -i inventories/pod22/hosts.yml playbooks/08_apply_baremetal_cluster.yml --ask-vault-pass
ansible-playbook -i inventories/pod22/hosts.yml playbooks/08_reboot_site_a_nodes.yml --ask-vault-pass
```

## iDRAC reset HTTP 409

If a Redfish `ComputerSystem.Reset` action returns HTTP `409 Conflict`, iDRAC is usually busy with an existing lifecycle/power/virtual-media operation. The restart playbook treats this as non-fatal, attempts a ForceOff/On fallback, and prints the final power state. If one node still reports 409, wait 60 seconds and rerun the restart playbook or power-cycle that node from the iDRAC UI.
