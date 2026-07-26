# HCP cleanup

Use the wrapper:

```bash
./scripts/hcp-delete.sh
```

This removes all four default HCP tenants and their RHACM imports:

| Site | HostedCluster / ManagedCluster | Control-plane namespace |
|---|---|---|
| Site-A | `site-a-hcp-t1-px` | `clusters-site-a-hcp-t1-px` |
| Site-A | `site-a-hcp-t2-kv` | `clusters-site-a-hcp-t2-kv` |
| Site-B | `site-b-hcp-t1-px` | `clusters-site-b-hcp-t1-px` |
| Site-B | `site-b-hcp-t2-kv` | `clusters-site-b-hcp-t2-kv` |

For a lab-only stuck namespace cleanup:

```bash
HCP_FORCE_CLEANUP=true ./scripts/hcp-delete.sh
```
