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
        | 3. Create hub-sno VM and boot ISO
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
| SNO hub node | 10.23.22.90 |
| SNO API DNS target | 10.23.22.90 |
| SNO Ingress DNS target | 10.23.22.90 |
| SNO reserved API VIP, vSphere platform mode only | 10.23.22.91 |
| SNO reserved Ingress VIP, vSphere platform mode only | 10.23.22.92 |
| Bare-metal API VIP | 10.23.22.120 |
| Bare-metal Ingress VIP | 10.23.22.121 |
| Bare-metal node b08-33 | 10.23.22.110 |
| Bare-metal node b08-34 | 10.23.22.111 |
| Bare-metal node b08-35 | 10.23.22.112 |
| Bare-metal node b08-36 | 10.23.22.113 |
| Bare-metal node b09-33 | 10.23.22.114 |
| Bare-metal node b09-34 | 10.23.22.115 |
| DNS / AD | 10.23.22.100 |
| Gateway | 10.23.22.1 |

## Bare-metal BMC plan

| Node | iDRAC/BMC IP | Default role | Boot MAC |
|---|---:|---|---|
| b08-33 | 10.23.22.80 | master | BC:97:E1:C3:F6:E0 |
| b08-34 | 10.23.22.81 | master | BC:97:E1:7E:99:60 |
| b08-35 | 10.23.22.82 | master | BC:97:E1:7E:99:F0 |
| b08-36 | 10.23.22.83 | worker | BC:97:E1:7E:98:D0 |
| b09-33 | 10.23.22.84 | worker | CHANGE_ME |
| b09-34 | 10.23.22.85 | worker | CHANGE_ME |

## Important notes

- The BMC/iDRAC IPs are not the OpenShift node IPs.
- DHCP is disabled, so the hub gets a static IP through `agent-config.yaml`, and each bare-metal host gets a static IP through `NMStateConfig`.
- The `boot_mac` must be the NIC MAC on the network used to reach the cluster machine network, currently VLAN 3522.
- Because there is no provisioning network, the BareMetalHost uses `redfish-virtualmedia://`.
- The iDRAC firmware versions should be aligned before the ACM provisioning run.
- b09-33 and b09-34 still need their boot NIC MACs filled in before the bare-metal playbook can run.

## 3-node compact option

To build only a compact 3-node bare-metal cluster:

```yaml
bm_control_plane_count: 3
bm_worker_count: 0

# Set enabled: false on b08-36, b09-33, b09-34
```

The first three nodes remain `role: master`. Assisted Installer will create a compact cluster where the control-plane nodes are schedulable.

## SNO platform note

The hub VM is created by Ansible on vSphere, but OpenShift is installed with `platform: none` by default. That keeps the lab independent of a vSphere compute-cluster name and matches the standalone ESXi inventory in pod-22.
