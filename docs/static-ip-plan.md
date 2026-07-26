# Static IP and DNS Plan

## VLAN / NIC mapping

| VM NIC | Linux name | Port group | VLAN | Mode |
|---|---|---|---|---|
| NIC 1 | ens192 | VLAN3522 | 3522 | Access |

## IP plan

| Purpose | Address |
|---|---|
| SNO node | 10.23.22.90 |
| API DNS target | 10.23.22.90 |
| Ingress DNS target | 10.23.22.90 |
| Reserved API VIP, only for `sno_install_platform: vsphere` | 10.23.22.91 |
| Reserved Ingress VIP, only for `sno_install_platform: vsphere` | 10.23.22.92 |
| Gateway | 10.23.22.1 |
| DNS | 10.23.22.100 |

## DNS

| Record | Target |
|---|---|
| api.hub-sno.poc.local | 10.23.22.90 |
| api-int.hub-sno.poc.local | 10.23.22.90 |
| *.apps.hub-sno.poc.local | 10.23.22.90 |
| hub-sno-0.hub-sno.poc.local | 10.23.22.90 |

## ACM managed bare-metal cluster IP plan

| Purpose | Address |
|---|---|
| Bare-metal API VIP | 10.23.22.120 |
| Bare-metal Ingress VIP | 10.23.22.121 |
| b08-33 OpenShift OS | 10.23.22.110 |
| b08-34 OpenShift OS | 10.23.22.111 |
| b08-35 OpenShift OS | 10.23.22.112 |
| b08-36 OpenShift OS | 10.23.22.113 |
| b09-33 OpenShift OS | 10.23.22.114 |
| b09-34 OpenShift OS | 10.23.22.115 |

## iDRAC/BMC IP plan

| Node | iDRAC/BMC IP |
|---|---|
| b08-33 | 10.23.22.80 |
| b08-34 | 10.23.22.81 |
| b08-35 | 10.23.22.82 |
| b08-36 | 10.23.22.83 |
| b09-33 | 10.23.22.84 |
| b09-34 | 10.23.22.85 |

The iDRAC/BMC IPs are intentionally separate from the OpenShift node OS IPs.

## SNO platform note

The default SNO install uses `sno_install_platform: none`, so the API and apps wildcard DNS records point to the single SNO node IP. The reserved VIPs are only used if you switch to `sno_install_platform: vsphere` and provide a real `vsphere_cluster` value.
