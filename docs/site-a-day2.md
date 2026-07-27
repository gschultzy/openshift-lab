# Day-2 hub setup and Site-A bare-metal cluster

This repo is preconfigured for the next Day-2 sequence after the `{{ cluster_name }}` cluster is installed.

## What this config does

1. Adds a second 800 GB thin VMDK to the SNO hub VM when it is missing.
2. Installs the LVM Storage Operator on the SNO hub.
3. Creates an `LVMCluster` using the second disk, expected as `/dev/sdb`.
4. Sets the generated LVM StorageClass `lvms-vg1` as the default StorageClass.
5. Installs Red Hat Advanced Cluster Management.
6. Configures Assisted Service storage to use the LVM default StorageClass.
7. Enables or validates bare-metal provisioning services.
8. Adds only these three Dell iDRAC nodes to ACM:
   - `{{ bm_nodes[0].name }}`
   - `{{ bm_nodes[1].name }}`
   - `{{ bm_nodes[2].name }}`
9. Provisions the bare-metal OpenShift cluster as `site-a` / display name `Site-A`.

## Run the full Day-2 flow

```bash
cd ~/OCP/ocp-sno-vsphere-ansible
source .venv/bin/activate

./scripts/run-site-a-day2.sh
```

Or run the combined playbook directly:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/11_configure_hub_and_site_a.yml --ask-vault-pass
```

## Run step-by-step

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/02_add_sno_extra_disk.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/05_install_lvm_storage.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/06_install_acm.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/07_configure_assisted_service.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/07_enable_baremetal_provisioning.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/10_configure_bm_ad_dns.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/05_idrac_preflight.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/08_apply_baremetal_cluster.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/09_wait_baremetal_cluster.yml --ask-vault-pass
```

## Important variables

```yaml
# LVM
sno_vm_extra_disk_enabled: true
sno_vm_extra_disk_gb: 800
lvm_device_paths:
  - /dev/sdb
lvm_storage_class_name: lvms-vg1
lvm_make_default_storageclass: true

# Site-A
bm_cluster_name: site-a
bm_cluster_display_name: Site-A
bm_control_plane_count: 3
bm_worker_count: 0
```

Only `{{ bm_nodes[0].name }}`, `{{ bm_nodes[1].name }}`, and `{{ bm_nodes[2].name }}` are enabled. The other Dell nodes are left in the inventory but disabled.

## Check the hub storage

```bash
export KUBECONFIG=$PWD/build/{{ cluster_name }}/install/auth/kubeconfig
oc get storageclass
oc -n openshift-storage get lvmcluster lvmcluster -o yaml
oc debug node/{{ cluster_name }}-0 -- chroot /host lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
```

If the second disk is not `/dev/sdb`, change `lvm_device_paths` in `inventories/env/group_vars/all/main.yml` and rerun `05_install_lvm_storage.yml`.

## Check Site-A provisioning

```bash
oc -n site-a get clusterdeployment,agentclusterinstall,infraenv,bmh,agent -o wide
oc -n site-a get nmstateconfig
oc get managedcluster site-a
```

## Bare-metal nodes fail with `coreos-livepxe-rootfs` 503

If the iDRAC console shows errors like:

```text
coreos-livepxe-rootfs: curl: (22) The requested URL returned error: 503
Failed to start Acquire Live PXE rootfs Image
```

then the node successfully booted the Assisted Installer image, but it cannot download the live
rootfs from the hub route:

```text
https://assisted-image-service-multicluster-engine.apps.{{ cluster_name }}.{{ base_domain }}/boot-artifacts/rootfs?arch=x86_64&version=4.22
```

Run the validation playbook before rebooting the bare-metal nodes:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/04_configure_ad_dns.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/07_validate_assisted_image_service.yml --ask-vault-pass
```

The important check is that the DNS server used by the bare-metal nodes resolves the hub wildcard apps route to the SNO IP:

```text
assisted-image-service-multicluster-engine.apps.{{ cluster_name }}.{{ base_domain }} -> {{ sno_node.ip }}
```

After the route and DNS pass, reboot the stuck nodes:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/08_reboot_site_a_nodes.yml --ask-vault-pass
```
