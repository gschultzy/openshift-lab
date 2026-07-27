# Portworx Enterprise with Everpure/Pure FlashArray

This repo deploys Portworx/Pure FlashArray preparation through RHACM policies from the hub.
The target clusters are the bare-metal managed clusters:

- `site-a`
- `site-b`

The hub remains the RHACM/MCE control point. The Portworx/Pure policies are pushed from the hub to the managed clusters.

## What the policies do

Policy namespace on the hub:

```bash
portworx-pure-policies
```

Policies:

```bash
portworx-pure-node-prep
portworx-operator
portworx-pure-secret
portworx-flasharray-storagecluster
```

The node prep policy creates MachineConfigs for both `master` and `worker` pools. It writes:

```bash
/etc/multipath.conf
/etc/udev/rules.d/99-pure-storage.rules
/etc/udev/rules.d/90-scsi-ua.rules
```

It also enables:

```bash
multipathd.service
```

`iscsid.service` is disabled by default because this lab is set to Fibre Channel:

```yaml
portworx_pure_san_type: FC
portworx_pure_enable_iscsid: false
```

## FlashArray details in this lab

```yaml
pure_flasharray_name: {{ pure_flasharray_name }}
pure_flasharray_mgmt_endpoint: {{ pure_flasharray_mgmt_endpoint }}
pure_flasharray_ct0_endpoint: {{ pure_flasharray_ct0_endpoint }}
pure_flasharray_ct1_endpoint: {{ pure_flasharray_ct1_endpoint }}
pure_flasharray_file_vip: {{ pure_flasharray_file_vip }}
pure_flasharray_username: pureuser
portworx_pure_san_type: FC
```

## API token required

Portworx `pure.json` needs a FlashArray API token, not the array login password.
Do not put the password in git.

Add this to your encrypted vault file:

```bash
ansible-vault edit inventories/env/group_vars/all/vault.yml
```

Add:

```yaml
vault_pure_flasharray_api_token: "{{ FLASHARRAY_API_TOKEN }}"
```

Generate the token on the FlashArray using the UI or CLI. CLI example:

```bash
pureadmin create --api-token
```

The policy creates this secret on each managed cluster:

```bash
namespace: portworx
secret: px-pure-secret
key: pure.json
```

## Run node prep first

This applies only the MachineConfig policy. It does not require the FlashArray API token.

```bash
cd ~/OCP/ocp-sno-vsphere-ansible
source .venv/bin/activate
export KUBECONFIG=$PWD/build/{{ cluster_name }}/install/auth/kubeconfig

./scripts/run-portworx-pure-node-prep.sh
```

The MachineConfig will roll/reboot the affected nodes. Wait for both clusters to settle:

```bash
oc get managedcluster
./scripts/check-portworx-pure.sh
```

## Run the full Portworx install

After the API token is in vault and the MachineConfigPools are healthy:

```bash
./scripts/run-portworx-pure-install.sh
```

This applies:

- Portworx Operator subscription
- `px-pure-secret`
- Portworx `StorageCluster` using FlashArray cloud drives

## Check status

```bash
./scripts/check-portworx-pure.sh
```

Manual checks:

```bash
oc -n portworx-pure-policies get policy,placement,placementdecision

oc --kubeconfig build/{{ cluster_name }}/site-a/auth/kubeconfig get mcp
oc --kubeconfig build/{{ cluster_name }}/site-a/auth/kubeconfig -n portworx get pods,storagecluster,secret/px-pure-secret
oc --kubeconfig build/{{ cluster_name }}/site-a/auth/kubeconfig get sc

oc --kubeconfig build/{{ cluster_name }}/site-b/auth/kubeconfig get mcp
oc --kubeconfig build/{{ cluster_name }}/site-b/auth/kubeconfig -n portworx get pods,storagecluster,secret/px-pure-secret
oc --kubeconfig build/{{ cluster_name }}/site-b/auth/kubeconfig get sc
```

## Notes

- The policies do not install a second MCE on Site-A or Site-B.
- The policies are not added to the default day-2 scripts because MachineConfig changes reboot nodes.
- The uploaded Pure multipath and udev files are copied into `files/pure/` and rendered into MachineConfig objects.
- The replacement Portworx 3.6.1.1 KDS StorageCluster template is kept as a normalized reference in `files/pure/px-3.6.1-stc-KDS-template.yml.reference`. The downloaded template had two `cloudStorage` keys; the policy keeps the same values under one `cloudStorage` block so `provider: pure`, `deviceSpecs`, and `journalDeviceSpec` all survive rendering.

## Automate FlashArray API token creation

The repo can now create/rotate the FlashArray API token automatically using the Pure Storage Ansible collection.

Keep the FlashArray login password in Ansible Vault only:

```bash
ansible-vault edit inventories/env/group_vars/all/vault.yml
```

Add:

```yaml
vault_pure_flasharray_password: "{{ FLASHARRAY_LOGIN_PASSWORD }}"
```

Then create/rotate the API token:

```bash
./scripts/create-pure-api-token.sh
```

The generated token is written to:

```text
build/{{ cluster_name }}/pure/generated-flasharray-token.yml
```

The file is local-only, mode `0600`, and under `build/`, so it is not committed to git. The Portworx policy playbook automatically loads it. If you prefer to manage the token yourself, put this directly in the encrypted vault instead:

```yaml
vault_pure_flasharray_api_token: "{{ FLASHARRAY_API_TOKEN }}"
```

One-shot flow:

```bash
./scripts/bootstrap-pure-token-and-portworx.sh
```

That creates/rotates the FlashArray API token, applies the node-prep policies, then applies the Portworx Operator and StorageCluster policies.

## If StorageCluster is Degraded immediately after policy apply

The node-prep policy writes MachineConfig objects for multipath, udev rules and SCSI unit-attention handling. That triggers a master MachineConfigPool rollout on Site-A and Site-B. Portworx should not be judged healthy until both sites finish that rollout.

Check/wait:

```bash
./scripts/wait-portworx-pure-node-prep.sh
./scripts/check-portworx-pure.sh
```

If the `StorageCluster` remains `Degraded` after both master MCPs are `UPDATED=True` and `UPDATING=False`, collect debug output:

```bash
./scripts/debug-portworx-pure-degraded.sh
```

The debug script prints hub policy placement, MCP state, Portworx resources, StorageCluster describe output, events, operator logs, and StorageClasses for both Site-A and Site-B.

## Enable the Portworx OpenShift Console plugin

The repo enables the Portworx OpenShift Dynamic Plugin by default with an RHACM
policy named `portworx-openshift-console-plugin`. The policy patches the OpenShift
Console operator on Site-A and Site-B so that `spec.plugins` includes `portworx`.

Run only the console-plugin policy without re-running node prep or recreating the
StorageCluster:

```bash
cd ~/OCP/ocp-sno-vsphere-ansible
source .venv/bin/activate
export KUBECONFIG=$PWD/build/{{ cluster_name }}/install/auth/kubeconfig

./scripts/run-portworx-console-plugin.sh
```

Validate it from each spoke:

```bash
oc --kubeconfig build/{{ cluster_name }}/site-a/auth/kubeconfig get console.operator cluster -o jsonpath='{.spec.plugins}{"\n"}'
oc --kubeconfig build/{{ cluster_name }}/site-a/auth/kubeconfig get consoleplugin portworx
oc --kubeconfig build/{{ cluster_name }}/site-a/auth/kubeconfig -n portworx get pods | egrep -i 'px-plugin|plugin|proxy|cache|NAME'

oc --kubeconfig build/{{ cluster_name }}/site-b/auth/kubeconfig get console.operator cluster -o jsonpath='{.spec.plugins}{"\n"}'
oc --kubeconfig build/{{ cluster_name }}/site-b/auth/kubeconfig get consoleplugin portworx
oc --kubeconfig build/{{ cluster_name }}/site-b/auth/kubeconfig -n portworx get pods | egrep -i 'px-plugin|plugin|proxy|cache|NAME'
```

Refresh the OpenShift Console browser tab after the policy applies. You should see
Portworx in the left navigation, and Portworx tabs on supported storage and
virtualization pages.

## OpenShift Console plugin

The repo enables the Portworx OpenShift Console plugin in two ways:

1. An RHACM policy named `portworx-openshift-console-plugin`.
2. A direct idempotent patch from `playbooks/25_enable_portworx_console_plugin_direct.yml` that appends `portworx` to `console.operator/cluster` without removing existing plugins such as `kubevirt-plugin`, `monitoring-plugin`, or `networking-console-plugin`.

Run only the console-plugin portion with:

```bash
./scripts/run-portworx-console-plugin.sh
```

Validate with:

```bash
oc --kubeconfig build/{{ cluster_name }}/site-a/auth/kubeconfig get console.operator cluster -o jsonpath='{.spec.plugins}{"\n"}'
oc --kubeconfig build/{{ cluster_name }}/site-b/auth/kubeconfig get console.operator cluster -o jsonpath='{.spec.plugins}{"\n"}'
```

## Fix stale local ACM/MCE API discovery on Site-A/Site-B

If Portworx is installed and the StorageCluster shows `Install=Completed`, `RuntimeState=Online`, or `Phase=Running`, but the operator repeatedly logs errors like this:

```text
unable to retrieve the complete list of server APIs:
clusterview.open-cluster-management.io/v1: stale GroupVersion discovery
proxy.open-cluster-management.io/v1beta1: stale GroupVersion discovery
```

then Site-A/Site-B still have stale local ACM/MCE aggregated API registrations left over from the earlier local-MCE experiment.

Run this from the RHACM hub context:

```bash
export KUBECONFIG=$PWD/build/{{ cluster_name }}/install/auth/kubeconfig
./scripts/cleanup-stale-ocm-apis-on-spokes.sh
./scripts/check-portworx-pure.sh
```

The cleanup deletes only these stale local APIService registrations from the spokes:

```text
v1.clusterview.open-cluster-management.io
v1alpha1.clusterview.open-cluster-management.io
v1beta1.proxy.open-cluster-management.io
```

It does not delete the RHACM import agent namespaces:

```text
open-cluster-management-agent
open-cluster-management-agent-addon
open-cluster-management-agent-addon-discovery
```
