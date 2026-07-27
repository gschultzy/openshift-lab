# Hub and Bare-Metal Spoke Architecture

## Goal

Build a small automated pod where:

1. A VMware VM is installed as a Single Node OpenShift hub using a static IP address.
2. Red Hat Advanced Cluster Management is installed onto that hub.
3. ACM / multicluster engine / Assisted Installer deploys the Dell bare-metal nodes as a managed OpenShift cluster.

## Flow

```text
Ubuntu 24.04 Ansible Controller
        |
        | 1. Render install-config.yaml + agent-config.yaml
        | 2. Create OpenShift Agent ISO with static networking
        v
vCenter / ESXi
        |
        | 3. Create {{ cluster_name }} VM and boot ISO
        v
SNO OpenShift Hub on VMware
        |
        | 4. Install ACM / MCE / Assisted Service
        | 5. Create ClusterDeployment, AgentClusterInstall, InfraEnv, NMStateConfig, BMH
        v
Dell PowerEdge Bare-Metal Nodes
        |
        | 6. Boot discovery ISO via iDRAC Redfish virtual media
        | 7. Register Agents, install OpenShift, import into ACM
        v
Managed bare-metal OpenShift cluster
```

## Default IP plan

| Purpose | Address |
|---|---:|
| SNO hub node | {{ sno_node.ip }} |
| SNO API DNS target | {{ sno_node.ip }} |
| SNO Ingress DNS target | {{ sno_node.ip }} |
| SNO reserved API VIP, vSphere platform mode only | {{ api_vip }} |
| SNO reserved Ingress VIP, vSphere platform mode only | {{ ingress_vip }} |
| Bare-metal API VIP | {{ bm_api_vip }} |
| Bare-metal Ingress VIP | {{ bm_ingress_vip }} |
| Bare-metal node {{ bm_nodes[0].name }} | {{ bm_nodes[0].ip }} |
| Bare-metal node {{ bm_nodes[1].name }} | {{ bm_nodes[1].ip }} |
| Bare-metal node {{ bm_nodes[2].name }} | {{ bm_nodes[2].ip }} |
| Bare-metal node {{ site_b_nodes[0].name }} | {{ site_b_nodes[0].ip }} |
| Bare-metal node {{ site_b_nodes[1].name }} | {{ site_b_nodes[1].ip }} |
| Bare-metal node {{ site_b_nodes[2].name }} | {{ site_b_nodes[2].ip }} |
| DNS / AD | {{ ad_dns_server }} |
| Gateway | {{ gateway }} |

## Bare-metal BMC plan

| Node | iDRAC/BMC IP | Default role | Boot MAC |
|---|---:|---|---|
| {{ bm_nodes[0].name }} | {{ bm_nodes[0].bmc_ip }} | master | {{ bm_nodes[0].boot_mac }} |
| {{ bm_nodes[1].name }} | {{ bm_nodes[1].bmc_ip }} | master | {{ bm_nodes[1].boot_mac }} |
| {{ bm_nodes[2].name }} | {{ bm_nodes[2].bmc_ip }} | master | {{ bm_nodes[2].boot_mac }} |
| {{ site_b_nodes[0].name }} | {{ site_b_nodes[0].bmc_ip }} | worker | {{ site_b_nodes[0].boot_mac }} |
| {{ site_b_nodes[1].name }} | {{ site_b_nodes[1].bmc_ip }} | worker | CHANGE_ME |
| {{ site_b_nodes[2].name }} | {{ site_b_nodes[2].bmc_ip }} | worker | CHANGE_ME |

## Important notes

- The BMC/iDRAC IPs are not the OpenShift node IPs.
- DHCP is disabled, so the hub gets a static IP through `agent-config.yaml`, and each bare-metal host gets a static IP through `NMStateConfig`.
- The `boot_mac` must be the NIC MAC on the network used to reach the cluster machine network, currently VLAN {{ machine_vlan_id }}.
- Because there is no provisioning network, the BareMetalHost uses `redfish-virtualmedia://`.
- The iDRAC firmware versions should be aligned before the ACM provisioning run.
- {{ site_b_nodes[1].name }} and {{ site_b_nodes[2].name }} still need their boot NIC MACs filled in before the bare-metal playbook can run.

## 3-node compact option

To build only a compact 3-node bare-metal cluster:

```yaml
bm_control_plane_count: 3
bm_worker_count: 0

# Set enabled: false on {{ site_b_nodes[0].name }}, {{ site_b_nodes[1].name }}, {{ site_b_nodes[2].name }}
```

The first three nodes remain `role: master`. Assisted Installer will create a compact cluster where the control-plane nodes are schedulable.

## SNO platform note

The hub VM is created by Ansible on vSphere, but OpenShift is installed with `platform: none` by default. That keeps the lab independent of a vSphere compute-cluster name and uses the vSphere objects configured in main.yml.
