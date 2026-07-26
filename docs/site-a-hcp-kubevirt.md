# Site-A as an HCP KubeVirt hosting cluster

This workflow keeps the SNO hub as the central RHACM hub, then prepares `site-a` as the hosting cluster for Hosted Control Planes using RHACM policies.

The policy set installs and configures the following on `site-a`:

- OpenShift Virtualization
- multicluster engine for Kubernetes
- MetalLB with five reserved HCP load-balancer IPs
- Ingress wildcard route admission set to `WildcardsAllowed`
- Optional LVM Storage policy, disabled by default until the spare disk paths on Site-A are confirmed

The test hosted cluster is then created from the Site-A kubeconfig with the `hcp create cluster kubevirt` CLI. The HCP control plane pods and KubeVirt worker VMs are hosted on Site-A.

## Important storage note

KubeVirt HCP requires persistent storage for the hosted control plane etcd and for worker VM disks. If Site-A does not already have a default StorageClass, either install ODF/LVM/Portworx first or enable the optional Site-A LVM policy after confirming unused disk paths.

The playbook `14_create_site_a_hcp_kubevirt_cluster.yml` auto-detects the default Site-A StorageClass. If none exists, set:

```yaml
site_a_hcp_etcd_storage_class: lvms-vg1
```

or install storage and make it default before creating the HCP cluster.

## Variables

Defaults are in `inventories/env/group_vars/all/main.yml`:

```yaml
site_a_hcp_metallb_range: 10.23.74.122-10.23.74.126
site_a_hcp_cluster_name: site-a-hcp-t1-px
site_a_hcp_namespace: clusters
site_a_hcp_nodepool_replicas: 3
site_a_hcp_worker_cores: 4
site_a_hcp_worker_memory: 8Gi
site_a_hcp_release_image: "{{ bm_cluster_release_image }}"
site_a_hcp_etcd_storage_class: ""
```

## Apply policies from the hub

```bash
cd ~/OCP/ocp-sno-vsphere-ansible
source .venv/bin/activate
export KUBECONFIG=$PWD/build/lab-sno/install/auth/kubeconfig

ansible-playbook -i inventories/env/hosts.yml playbooks/12_apply_site_a_hcp_policies.yml --ask-vault-pass
```

## Watch policy compliance

```bash
oc -n site-a-policies get policy -w
oc get managedcluster site-a --show-labels
```

## Wait for Site-A prerequisites

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/13_wait_site_a_hcp_prereqs.yml --ask-vault-pass
```

This extracts the Site-A kubeconfig to:

```text
build/lab-sno/site-a/auth/kubeconfig
```

## Validate Site-A manually

```bash
SITEA_KUBECONFIG=$PWD/build/lab-sno/site-a/auth/kubeconfig

oc --kubeconfig $SITEA_KUBECONFIG get co
oc --kubeconfig $SITEA_KUBECONFIG -n openshift-cnv get hyperconverged,pods
oc --kubeconfig $SITEA_KUBECONFIG get multiclusterengine
oc --kubeconfig $SITEA_KUBECONFIG -n metallb-system get metallb,ipaddresspool,l2advertisement,pods
oc --kubeconfig $SITEA_KUBECONFIG -n openshift-ingress-operator get ingresscontroller default -o yaml | grep -A3 routeAdmission
oc --kubeconfig $SITEA_KUBECONFIG get sc
```

## Create the HCP KubeVirt test cluster from Site-A

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/14_create_site_a_hcp_kubevirt_cluster.yml --ask-vault-pass
```

The playbook installs/downloads the `hcp` CLI into `build/lab-sno/bin/hcp`, writes a temporary pull secret under `build/lab-sno/site-a-hcp/`, and runs:

```bash
hcp create cluster kubevirt \
  --name site-a-hcp-t1-px \
  --namespace clusters \
  --node-pool-replicas 3 \
  --pull-secret build/lab-sno/site-a-hcp/pull-secret.json \
  --ssh-key build/lab-sno/site-a-hcp/ssh.pub \
  --memory 8Gi \
  --cores 4 \
  --etcd-storage-class <detected-or-configured-storageclass> \
  --release-image quay.io/openshift-release-dev/ocp-release:4.21.20-x86_64
```

## Watch the hosted cluster

```bash
SITEA_KUBECONFIG=$PWD/build/lab-sno/site-a/auth/kubeconfig

oc --kubeconfig $SITEA_KUBECONFIG -n clusters get hostedcluster,nodepool -w
oc --kubeconfig $SITEA_KUBECONFIG -n clusters-site-a-hcp-t1-px get pods -w
```

## Get hosted cluster kubeconfig

```bash
SITEA_KUBECONFIG=$PWD/build/lab-sno/site-a/auth/kubeconfig
build/lab-sno/bin/hcp create kubeconfig \
  --namespace clusters \
  --name site-a-hcp-t1-px \
  > build/lab-sno/site-a-hcp/site-a-hcp-t1-px.kubeconfig

oc --kubeconfig build/lab-sno/site-a-hcp/site-a-hcp-t1-px.kubeconfig get nodes
oc --kubeconfig build/lab-sno/site-a-hcp/site-a-hcp-t1-px.kubeconfig get co
```

## Hub visibility

The policy playbook creates a `ManagedClusterAddOn` called `hypershift-addon` in the `site-a` namespace on the hub and patches the hub add-on deployment config for MCE hosted-cluster discovery when that object exists. The expected model is:

- `lab-sno`: central RHACM hub
- `site-a`: RHACM managed cluster and HCP/MCE hosting cluster
- `site-a-hcp-t1-px`: hosted cluster created from Site-A

After the hosted API is available, check discovery/import from the hub:

```bash
export KUBECONFIG=$PWD/build/lab-sno/install/auth/kubeconfig
oc get managedcluster
oc -n site-a get managedclusteraddon hypershift-addon
oc get discoveredcluster -A 2>/dev/null || true
```


## MetalLB OperatorGroup failure: OwnNamespace not supported

If MetalLB fails with `OwnNamespace InstallModeType not supported, cannot configure to watch own namespace`, the OperatorGroup was scoped to its own namespace. MetalLB must use an OperatorGroup without `spec.targetNamespaces`. The corrected policy uses `mustonlyhave` and renders the OperatorGroup as:

```yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: metallb-operator-group
  namespace: metallb-system
```

If an old failed install exists on Site-A, clean it up before reapplying the corrected policy:

```bash
oc --kubeconfig $SITEA_KUBECONFIG -n metallb-system delete subscription metallb-operator --ignore-not-found
oc --kubeconfig $SITEA_KUBECONFIG -n metallb-system delete csv -l operators.coreos.com/metallb-operator.metallb-system= --ignore-not-found
oc --kubeconfig $SITEA_KUBECONFIG -n metallb-system delete installplan --all --ignore-not-found
oc --kubeconfig $SITEA_KUBECONFIG -n metallb-system delete operatorgroup metallb-operator-group --ignore-not-found
```

## If HCP creation stops because Site-A has no StorageClass

Run the LVM storage playbook after confirming the unused disk path on each Site-A node:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/15_install_site_a_lvm_storage.yml --ask-vault-pass
```

If `site_a_lvm_device_paths` is empty, the playbook stops after printing `lsblk` from each node. Set the correct unused disk path in `inventories/env/group_vars/all/main.yml`, for example:

```yaml
site_a_lvm_device_paths:
  - /dev/sdb
site_a_lvm_make_default_storageclass: true
site_a_hcp_etcd_storage_class: "{{ site_a_lvm_storage_class_name }}"
```

For a disposable lab only, you can set `site_a_lvm_allow_all_unused_devices: true` to allow LVMS to claim all unused disks automatically.

## Fixing policy placement when Site-A is Available=Unknown

If the Site-A managed cluster has the correct `hcp-hosting=true` and ClusterSet labels but the placement still shows `NoManagedClusterMatched`, the managed cluster is usually tainted `unreachable` or `unavailable` with `NoSelect`. For this lab, run:

```bash
ansible-playbook -i inventories/env/hosts.yml playbooks/12_fix_site_a_policy_placement.yml --ask-vault-pass
```

This creates or repairs the `ManagedClusterSet`, `ManagedClusterSetBinding`, Site-A labels, and placement tolerations.
