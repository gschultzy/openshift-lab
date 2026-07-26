# vSphere ISO upload options

The SNO Agent ISO must be available on a datastore before the VM can be booted.

This repo supports two upload methods controlled by `iso_upload_method`.

## `esxi_ssh` default

This is the default for the pod-22 lab because vCenter datastore folder creation can return HTTP 404 for paths that do not already exist.

The playbook connects to the ESXi host over SSH, creates the datastore folder directly, uploads the ISO with SCP, and then creates the VM through vCenter.

Example variables:

```yaml
iso_upload_method: esxi_ssh
esxi_hostname: "{{ vsphere_esxi_hostname }}"
esxi_username: root
esxi_password: "{{ vault_esxi_password }}"
esxi_datastore_mount: "/vmfs/volumes/{{ vsphere_datastore }}"
iso_datastore_folder: iso/ocp
```

Resulting ESXi file path:

```text
/vmfs/volumes/datastore1/iso/ocp/hub-sno-agent.x86_64.iso
```

Resulting vCenter ISO reference:

```text
[datastore1] iso/ocp/hub-sno-agent.x86_64.iso
```

Requirements:

- SSH enabled on the ESXi host.
- `sshpass` installed on the Ubuntu bastion.
- `vault_esxi_password` set in the encrypted vault file.

## `vcenter_api`

This uses `community.vmware.vsphere_file` and `community.vmware.vsphere_copy` through the vCenter datastore HTTP API.

Use it only if your vCenter/datastore path supports folder creation/upload through those modules:

```yaml
iso_upload_method: vcenter_api
```

## ESXi says `Device or resource busy` when uploading the ISO

If the SNO VM has already booted with an ISO mounted, ESXi can lock that ISO file.
Overwriting the same datastore path with `scp` can fail with:

```text
scp: /vmfs/volumes/datastore1/iso/ocp/hub-sno-agent.x86_64.iso: Device or resource busy
```

The repo defaults to `iso_unique_per_upload: true`, which uploads each run to a
fresh filename such as `hub-sno-agent-1782472999.x86_64.iso` and then attaches
that ISO to the VM. This avoids overwriting a locked file.

Old ISO files can be cleaned up later from ESXi after the VM is no longer using
them:

```bash
ssh root@10.23.22.11 'ls -lh /vmfs/volumes/datastore1/iso/ocp'
```
