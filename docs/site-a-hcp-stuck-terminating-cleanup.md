# Site-A HCP stuck Terminating cleanup

Use this only for the lab Site-A HCP test cluster when `clusters-site-a-hcp-t1-px` or `klusterlet-site-a-hcp-t1-px` is stuck in `Terminating` and the HCP is being rebuilt.

The symptom is usually:

```bash
oc --kubeconfig build/hub-sno/site-a/auth/kubeconfig get ns clusters-site-a-hcp-t1-px
# NAME                STATUS        AGE
# clusters-site-a-hcp-t1-px   Terminating   ...
```

In this lab, the Site-A HCP was also imported into RHACM as `site-a-hcp-t1-px`, so delete/import cleanup must happen on the hub first, then stale HCP/namespace resources can be cleared on Site-A.

## Cleanup

```bash
cd ~/OCP/ocp-sno-vsphere-ansible
source .venv/bin/activate

SITE_A_HCP_NAME=site-a-hcp-t1-px ./scripts/force-clean-site-a-hcp.sh
```

The script validates that:

- `build/hub-sno/install/auth/kubeconfig` points at `hub-sno`
- `build/hub-sno/site-a/auth/kubeconfig` points at `site-a`

Then it:

1. Deletes/unimports the RHACM `ManagedCluster` named `site-a-hcp-t1-px`.
2. Deletes the Site-A `DiscoveredCluster` for the HCP.
3. Deletes/clears finalizers on the Site-A `HostedCluster` and `NodePool`.
4. Clears the stuck namespaces `clusters-site-a-hcp-t1-px` and `klusterlet-site-a-hcp-t1-px`.
5. If already terminating, clears stale old local-MCE namespaces on Site-A: `multicluster-engine` and `open-cluster-management-hub`.
6. Deletes stale local-MCE APIService objects from Site-A if present.

## Recreate

The non-overlapping guest networks are now the default. Recreate both lab HCPs with:

```bash
./scripts/hcp-create.sh
```

Or recreate in place:

```bash
HCP_RECREATE=true ./scripts/hcp-create.sh
```

## Check

```bash
./scripts/export-hcp-kubeconfigs.sh
oc --kubeconfig build/hub-sno/hcp-kubeconfigs/site-a-hcp-t1-px.kubeconfig get clusterversion,nodes,co
```

