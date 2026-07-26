# Static IP and DNS Plan

## VLAN / NIC mapping

| VM NIC | Linux name | Port group | VLAN | Mode |
|---|---|---|---|---|
| NIC 1 | ens192 | VLAN3574 | 3574 | Access |

## IP plan

| Purpose | Address |
|---|---|
| SNO node | 10.23.74.90 |
| API DNS target | 10.23.74.90 |
| Ingress DNS target | 10.23.74.90 |
| Reserved API VIP, only for `sno_install_platform: vsphere` | 10.23.74.91 |
| Reserved Ingress VIP, only for `sno_install_platform: vsphere` | 10.23.74.92 |
| Gateway | 10.23.74.1 |
| DNS | 10.23.74.100 |

## DNS

| Record | Target |
|---|---|
| api.lab-sno.poc.local | 10.23.74.90 |
| api-int.lab-sno.poc.local | 10.23.74.90 |
| *.apps.lab-sno.poc.local | 10.23.74.90 |
| lab-sno-0.lab-sno.poc.local | 10.23.74.90 |

## ACM managed bare-metal cluster IP plan

| Purpose | Address |
|---|---|
| Bare-metal API VIP | 10.23.74.120 |
| Bare-metal Ingress VIP | 10.23.74.121 |
| b10-30 OpenShift OS | 10.23.74.110 |
| b10-31 OpenShift OS | 10.23.74.111 |
| b10-33 OpenShift OS | 10.23.74.112 |
| b10-34 OpenShift OS | 10.23.74.113 |
| b10-35 OpenShift OS | 10.23.74.114 |
| b10-36 OpenShift OS | 10.23.74.115 |

## iDRAC/BMC IP plan

| Node | iDRAC/BMC IP |
|---|---|
| b10-30 | 10.23.74.81 |
| b10-31 | 10.23.74.82 |
| b10-33 | 10.23.74.83 |
| b10-34 | 10.23.74.84 |
| b10-35 | 10.23.74.85 |
| b10-36 | 10.23.74.86 |

The iDRAC/BMC IPs are intentionally separate from the OpenShift node OS IPs.

## SNO platform note

The default SNO install uses `sno_install_platform: none`, so the API and apps wildcard DNS records point to the single SNO node IP. The reserved VIPs are only used if you switch to `sno_install_platform: vsphere` and provide a real `vsphere_cluster` value.
