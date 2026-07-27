# Portworx Enterprise with a dedicated Pure FlashArray per site

The hub applies two isolated RHACM policy bundles:

| Hosting cluster | FlashArray | Management endpoint |
|---|---|---|
| Site-A (`site-a`) | `{{ site_a_pure_flasharray_name }}` | `{{ site_a_pure_flasharray_mgmt_endpoint }}` |
| Site-B (`site-b`) | `{{ site_b_pure_flasharray_name }}` | `{{ site_b_pure_flasharray_mgmt_endpoint }}` |

Each managed cluster receives the standard target objects in its local `portworx` namespace:

- `Secret/px-pure-secret`
- `StorageCluster/px-cluster-flasharray`
- Portworx Operator subscription and supporting resources

The RHACM objects on the hub are site-suffixed so credentials and placement cannot cross sites:

```text
portworx-pure-secret-site-a
portworx-flasharray-storagecluster-site-a
portworx-pure-secret-site-b
portworx-flasharray-storagecluster-site-b
```

## Why the policies are separate

These arrays are treated as independent backends, not as an ActiveCluster pair. Site-A's `pure.json` contains only `{{ site_a_pure_flasharray_mgmt_endpoint }}`; Site-B's contains only `{{ site_b_pure_flasharray_mgmt_endpoint }}`. Do not put both arrays into both clusters' `pure.json` files unless the arrays are deliberately configured as an Everpure ActiveCluster pair and that architecture has been validated.

The hub labels the managed clusters as follows:

```text
site-a: portworx-pure-site=site-a
site-b: portworx-pure-site=site-b
```

Each site has its own Placement and PlacementBinding in `portworx-pure-policies`.

## Inventory source of truth

All non-secret values are under `inventories/env/group_vars/all/main.yml`:

```yaml
site_a_pure_flasharray_name: "{{ site_a_pure_flasharray_name }}"
site_a_pure_flasharray_mgmt_endpoint: "{{ site_a_pure_flasharray_mgmt_endpoint }}"

site_b_pure_flasharray_name: "{{ site_b_pure_flasharray_name }}"
site_b_pure_flasharray_mgmt_endpoint: "{{ site_b_pure_flasharray_mgmt_endpoint }}"
```

The complete declarative mapping is `portworx_pure_sites`. Token generation, policy rendering, validation, and status checks all consume that list.

## Secrets

Store credentials only in the encrypted file:

```bash
ansible-vault edit inventories/env/group_vars/all/vault.yml
```

Recommended variables:

```yaml
vault_site_a_pure_flasharray_password: "<SITE_A_LOGIN_PASSWORD>"
vault_site_a_pure_flasharray_api_token: ""

vault_site_b_pure_flasharray_password: "<SITE_B_LOGIN_PASSWORD>"
vault_site_b_pure_flasharray_api_token: ""
```

An API token can be supplied directly, or generated from the login password. The generated token files are:

```text
build/lab-sno/pure/site-a-generated-flasharray-token.yml
build/lab-sno/pure/site-b-generated-flasharray-token.yml
```

They are created with mode `0600` and remain under `build/`.

## FC prerequisites outside Kubernetes

The management endpoint in `px-pure-secret` controls API operations. Fibre Channel data access still requires correct SAN configuration.

Before installing Portworx, confirm:

1. Every Site-A node HBA WWPN is registered on `{{ site_a_pure_flasharray_name }}`.
2. Every Site-B node HBA WWPN is registered on `{{ site_b_pure_flasharray_name }}`.
3. Site-A initiators are zoned to both Site-A array controller target ports.
4. Site-B initiators are zoned to both Site-B array controller target ports.
5. No Site-A host group contains Site-B initiators, and vice versa.
6. Each node sees redundant paths after the MachineConfig rollout.

The controller interface addresses stored in `main.yml` are documentation values; Portworx `pure.json` uses the management endpoint and API token.

## Deployment flow

Build both bare-metal clusters first:

```bash
./scripts/run-full-hub-and-spoke.sh
```

Generate both array API tokens:

```bash
./scripts/create-pure-api-token.sh
```

Or generate only one site:

```bash
SITE=site-a ./scripts/create-pure-api-token.sh
SITE=site-b ./scripts/create-pure-api-token.sh
```

Apply node preparation. This writes multipath and Pure udev configuration through MachineConfig and rolls the node pools:

```bash
./scripts/run-portworx-pure-node-prep.sh
./scripts/wait-portworx-pure-node-prep.sh
```

Apply the Operator, each site's dedicated `px-pure-secret`, each StorageCluster, console plugin, and HCP StorageClasses:

```bash
./scripts/run-portworx-pure-install.sh
```

A single site can be targeted for testing:

```bash
SITE=site-a ./scripts/run-portworx-pure-node-prep.sh
SITE=site-a ./scripts/run-portworx-pure-install.sh

SITE=site-b ./scripts/run-portworx-pure-node-prep.sh
SITE=site-b ./scripts/run-portworx-pure-install.sh
```

The normal production-like lab flow should deploy Site-A first, validate it, then repeat for Site-B.

## Validation

Run:

```bash
./scripts/check-portworx-pure.sh
```

The status playbook now fails if:

- Site-A's `px-pure-secret` does not contain exactly `{{ site_a_pure_flasharray_mgmt_endpoint }}`.
- Site-B's `px-pure-secret` does not contain exactly `{{ site_b_pure_flasharray_mgmt_endpoint }}`.
- A secret is missing or contains multiple unexpected endpoints.

Manual checks:

```bash
HUB=build/lab-sno/install/auth/kubeconfig
oc --kubeconfig "$HUB" get managedcluster -L portworx-pure-site
oc --kubeconfig "$HUB" -n portworx-pure-policies get policy,placement,placementdecision,placementbinding

for site in site-a site-b; do
  K="build/lab-sno/${site}/auth/kubeconfig"
  echo "### ${site}"
  oc --kubeconfig "$K" -n portworx get storagecluster px-cluster-flasharray
  oc --kubeconfig "$K" -n portworx get pods -o wide
  oc --kubeconfig "$K" -n portworx get secret px-pure-secret \
    -o jsonpath='{.data.pure\.json}' | base64 -d | jq '{FlashArrays: [.FlashArrays[] | {MgmtEndPoint}]}'
done
```

Do not print the complete secret in shared logs because it contains API tokens.

## Array-specific cleanup

The destructive cleanup script now requires an explicit site when working on Site-B:

```bash
SITE=site-a ./scripts/cleanup-pure-portworx-volumes.sh
SITE=site-b ./scripts/cleanup-pure-portworx-volumes.sh
```

It removes only matching Portworx-created volume names on the selected array. Always verify the displayed site and array before entering the confirmation token.

## OpenShift 4.22 support warning

This lab pins Portworx Enterprise `3.6.1.1`. The published Portworx Enterprise 3.6.1 support matrix currently lists OpenShift through 4.21, while PX-CSI 26.2 lists OpenShift 4.22. The inventory therefore marks this as a POC acknowledgement with `portworx_poc_allow_ocp_4_22: true`. Obtain an Everpure support statement or use a qualified version before production deployment.
