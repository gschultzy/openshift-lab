# Troubleshooting

This file contains the longer debug and recovery notes that used to live in the root README.

---

## Hub kubeconfig must point at the hub

Many policy and HCP scripts must run against the hub API, not Site-A or Site-B.

```bash
cd /path/to/openshift-lab
source .venv/bin/activate

export HUB_KUBECONFIG=$PWD/build/{{ cluster_name }}/install/auth/kubeconfig
export KUBECONFIG=$HUB_KUBECONFIG

oc whoami --show-server
oc get managedcluster -o wide
```

The server must be:

```text
https://api.{{ cluster_name }}.{{ base_domain }}:6443
```

Repair the hub kubeconfig if it points at Site-A or Site-B:

```bash
./scripts/repair-hub-kubeconfig.sh
./scripts/fix-hub-kubeconfig-and-policies.sh
```

---

## RHACM managed cluster shows Unknown

Run the hub-side ACM/MCE integration repair:

```bash
./scripts/run-acm-mce-integration.sh
```

Then check:

```bash
oc get managedcluster
oc -n site-a get managedclusteraddon
oc -n site-b get managedclusteraddon
```

Site-A and Site-B should not have local MCE installed. They are managed spokes; the central hub owns RHACM/MCE and the HyperShift add-on.

---

## Site-A or Site-B policy page is empty

Apply the site policies again:

```bash
./scripts/run-site-a-policies.sh
./scripts/run-site-b-policies.sh
```

Check placement and bindings:

```bash
oc -n site-a-policies get policy,placement,placementbinding,placementdecision
oc -n site-b-policies get policy,placement,placementbinding,placementdecision
```

---

## Bare-metal node does not get its static IP

Check the NMStateConfig resources:

```bash
oc -n site-a get nmstateconfig -o yaml
oc -n site-b get nmstateconfig -o yaml
```

For these Dell nodes, the expected RHCOS interface name is usually:

```text
eno33np0
```

For Site-B, rerun iDRAC NIC discovery if the b09 MAC placeholders changed:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/05_discover_site_b_idrac_nics.yml --ask-vault-pass
```

Reset discovery objects after changing MACs or NMState:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/08_reset_site_a_for_nmstate_fix.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/08_reset_site_b_for_nmstate_fix.yml --ask-vault-pass
```

---

## Agent ISO or Assisted Service problems

Validate the Assisted Image Service route:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/07_validate_assisted_image_service.yml --ask-vault-pass
```

If the hub flow stops waiting for `assisted-service`, run:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/07_debug_assisted_service.yml --ask-vault-pass
```

Check for unbound PVCs, ImagePullBackOff, CrashLoopBackOff, route issues, or pod scheduling errors.

---

## Site-B install stops after InfraEnv ISO generation

Rerun the Site-B reboot and wait playbooks:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/08_reboot_site_b_nodes.yml --ask-vault-pass
ansible-playbook -i inventories/env/hosts.yml playbooks/09_wait_site_b_baremetal_cluster.yml --ask-vault-pass
```

---

## Enable or disable Portworx policy enforcement

Disable StorageCluster enforcement while cleaning Pure or rebuilding nodes:

```bash
HUB=build/{{ cluster_name }}/install/auth/kubeconfig

for site in site-a site-b; do
  oc --kubeconfig "$HUB" -n portworx-pure-policies patch policy "portworx-flasharray-storagecluster-${site}" \
    --type=merge \
    -p '{"spec":{"disabled":true}}'
done
```

Enable it again:

```bash
for site in site-a site-b; do
  oc --kubeconfig "$HUB" -n portworx-pure-policies patch policy "portworx-flasharray-storagecluster-${site}" \
    --type=merge \
    -p '{"spec":{"disabled":false}}'
done
```

Enable all Portworx policies if you disabled more than one:

```bash
for site in site-a site-b; do
  for base in \
    portworx-pure-node-prep \
    portworx-operator \
    portworx-pure-secret \
    portworx-flasharray-storagecluster \
    portworx-openshift-console-plugin \
    portworx-hcp-storageclasses
  do
    oc --kubeconfig "$HUB" -n portworx-pure-policies patch policy "${base}-${site}" \
      --type=merge \
      -p '{"spec":{"disabled":false}}'
  done
done
```

---

## Portworx stuck Initializing with Pure duplicate DriveSet matches

Symptoms:

```text
StorageCluster px-cluster-flasharray: Initializing
Portworx installation completed on 0/3 nodes, 3 nodes remaining
px-cluster-flasharray-* 0/1 Running
portworx-api-* CrashLoopBackOff
portworx-kvdb-service has no endpoints
```

PX logs may show:

```text
failed to initialize internal kvdb
failed to provision internal kvdb
Found more than one match: [...]
Not cleaning up cloud drives
```

This usually means old Pure cloud-drive / DriveSet volumes from a previous Portworx install are still visible to the rebuilt nodes.

First disable the StorageCluster policy:

```bash
HUB=build/{{ cluster_name }}/install/auth/kubeconfig
for site in site-a site-b; do
  oc --kubeconfig "$HUB" -n portworx-pure-policies patch policy "portworx-flasharray-storagecluster-${site}" \
    --type=merge \
    -p '{"spec":{"disabled":true}}'
done
```

Then clean the old Pure volumes:

```bash
SITE=site-a ./scripts/cleanup-pure-portworx-volumes.sh
# or
SITE=site-b ./scripts/cleanup-pure-portworx-volumes.sh
```

The script removes matching Portworx-created Pure volumes:

```text
pxclouddrive-*
px_*pvc-*
```

If Pure SafeMode blocks immediate eradication, make sure the volumes are at least disconnected and destroyed. Eradication can complete later when SafeMode allows it.

Re-enable StorageCluster enforcement:

```bash
for site in site-a site-b; do
  oc --kubeconfig "$HUB" -n portworx-pure-policies patch policy "portworx-flasharray-storagecluster-${site}" \
    --type=merge \
    -p '{"spec":{"disabled":false}}'
done
```

Watch Portworx:

```bash
watch -n 10 '
for site in site-a site-b; do
  K=build/{{ cluster_name }}/${site}/auth/kubeconfig
  echo
  echo "### $site"
  oc --kubeconfig "$K" -n portworx get storagecluster px-cluster-flasharray 2>/dev/null || true
  oc --kubeconfig "$K" -n portworx get pods | egrep "px-cluster|portworx-api|kvdb|csi|stork|cert-manager" || true
  oc --kubeconfig "$K" -n portworx get endpoints portworx-kvdb-service portworx-service portworx-api 2>/dev/null || true
done
'
```

---

## Local Portworx state is busy during node wipe

If removing local state gives:

```text
/var/lib/osd/lttng: Device or resource busy
/opt/pwx/oci: Device or resource busy
```

Delete Portworx runtime objects first, then force-unmount host paths with `nsenter`:

```bash
for site in site-a site-b; do
  K="build/{{ cluster_name }}/${site}/auth/kubeconfig"

  oc --kubeconfig "$K" -n portworx delete storagecluster px-cluster-flasharray --ignore-not-found --wait=false
  oc --kubeconfig "$K" -n portworx delete pod --all --ignore-not-found --wait=false
  oc --kubeconfig "$K" -n kube-system delete configmap px-bootstrap-pxclusterflasharray --ignore-not-found

  for node in $(oc --kubeconfig "$K" get nodes -o name | cut -d/ -f2); do
    oc --kubeconfig "$K" debug node/"$node" -- nsenter -a -t 1 -- bash -c '
      systemctl stop portworx 2>/dev/null || true
      pkill -9 -f portworx || true
      pkill -9 -f px-runc || true
      pkill -9 -f px-oci-mon || true
      for m in $(mount | awk "/\/var\/lib\/osd|\/opt\/pwx|pwx|px/ {print \\$3}" | sort -r); do
        umount -lf "$m" 2>/dev/null || true
      done
      rm -rf /etc/pwx /var/lib/osd /var/cores/px* /opt/pwx
    '
  done
done
```

If the paths remain busy during a full lab rebuild, reboot the nodes.

---

## HCP delete is stuck

Normal delete:

```bash
./scripts/hcp-delete.sh
```

Lab-only forced cleanup:

```bash
HCP_FORCE_CLEANUP=true ./scripts/hcp-delete.sh
```

Check host-side resources:

```bash
oc --kubeconfig build/{{ cluster_name }}/site-a/auth/kubeconfig -n clusters get hostedcluster,nodepool,pvc,pod
oc --kubeconfig build/{{ cluster_name }}/site-b/auth/kubeconfig -n clusters get hostedcluster,nodepool,pvc,pod
```

Check hub imports:

```bash
oc --kubeconfig build/{{ cluster_name }}/install/auth/kubeconfig get managedcluster
oc --kubeconfig build/{{ cluster_name }}/install/auth/kubeconfig get ns | egrep 'site-a-hcp-t1-px|site-b-hcp-t1-px'
```

---

## HCP guest kubeconfigs

Exported guest kubeconfigs live here:

```text
build/{{ cluster_name }}/hcp-kubeconfigs/site-a-hcp-t1-px.kubeconfig
build/{{ cluster_name }}/hcp-kubeconfigs/site-b-hcp-t1-px.kubeconfig
```

Example checks:

```bash
oc --kubeconfig build/{{ cluster_name }}/hcp-kubeconfigs/site-a-hcp-t1-px.kubeconfig get nodes
oc --kubeconfig build/{{ cluster_name }}/hcp-kubeconfigs/site-b-hcp-t1-px.kubeconfig get clusterversion
```

---

## Reset local hub build directory only

This does not delete the VM. It only removes local build artifacts:

```bash
./scripts/reset-sno-hub-build.sh
```

## ACM MultiClusterHub appears stuck in Installing

The main runners use `scripts/wait-acm-ready.sh` after applying the ACM Operator and
`MultiClusterHub`. The monitor prints the current MCH phase and conditions, OLM CSV
phase, non-ready ACM/MCE pods, degraded cluster operators, and recent warning events.

Run a one-time diagnostic report with:

```bash
./scripts/check-acm.sh
```

Resume the idempotent Site-A flow with:

```bash
./scripts/run-site-a-day2.sh
```

The timeout and polling interval are configured in
`inventories/env/group_vars/all/main.yml`:

```yaml
acm_wait_timeout_seconds: 3600
acm_wait_poll_seconds: 30
```

Do not delete the `MultiClusterHub` merely because installation takes longer than
expected. First check Pending pods, image pulls, insufficient CPU or memory, failed
OLM CSVs, PVCs, and warning events using the diagnostic script.
