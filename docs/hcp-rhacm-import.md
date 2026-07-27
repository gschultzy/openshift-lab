# HCP RHACM import

HCP import is no longer a separate user step.

Run this instead:

```bash
./scripts/hcp-create.sh
```

The create script exports all guest kubeconfigs and imports all HCP guest clusters into RHACM:

| HostedCluster | RHACM ManagedCluster | Guest kubeconfig |
|---|---|---|
| `site-a-hcp-t1-px` | `site-a-hcp-t1-px` | `build/{{ cluster_name }}/hcp-kubeconfigs/site-a-hcp-t1-px.kubeconfig` |
| `site-a-hcp-t2-kv` | `site-a-hcp-t2-kv` | `build/{{ cluster_name }}/hcp-kubeconfigs/site-a-hcp-t2-kv.kubeconfig` |
| `site-b-hcp-t1-px` | `site-b-hcp-t1-px` | `build/{{ cluster_name }}/hcp-kubeconfigs/site-b-hcp-t1-px.kubeconfig` |
| `site-b-hcp-t2-kv` | `site-b-hcp-t2-kv` | `build/{{ cluster_name }}/hcp-kubeconfigs/site-b-hcp-t2-kv.kubeconfig` |

The lower-level `export-hcp-kubeconfigs.sh` and `import-hcp-guests-to-hub.sh` scripts are kept as helpers for the create flow.
