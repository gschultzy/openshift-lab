# HCP hosting models for this lab

There are two valid ways to think about HCP in this repo.

## Recommended lab model: hub-managed HCP hosting

Use this when you want one RHACM/MCE hub to manage Site-A and Site-B.

- `hub-sno` runs RHACM and MCE.
- `site-a` and `site-b` are managed clusters.
- The hub enables the `hypershift-addon` on Site-A and Site-B.
- The HyperShift Operator is installed on Site-A/Site-B by that add-on.
- Hosted control plane pods and KubeVirt worker VMs run on Site-A or Site-B.
- You create and observe HCP from the hub workflow, while the actual hosting resources land on the selected site.

This is why Site-A/Site-B do not need a full local MCE install in the simple lab path.

Command:

```bash
./scripts/hcp-create.sh
```

This creates and imports both `site-a-hcp-t1-px` and `site-b-hcp-t1-px`.

## Distributed MCE hosting model

Use this only when Site-A and Site-B must be standalone HCP management clusters with their own MCE console and local `Create cluster` workflow.

In that model:

- Site-A and Site-B each run MCE.
- The central RHACM hub imports those MCE clusters using the MCE import pattern and namespace isolation.
- Do not use the normal managed cluster import model for those same clusters.
- Do not install full ACM on Site-A/Site-B unless you are intentionally building multiple hubs.

This model is more complex and is not the default path in this repo.
