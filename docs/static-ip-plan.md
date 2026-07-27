# Static IP and DNS Plan

## VLAN / NIC mapping

| VM NIC | Linux name | Port group | VLAN | Mode |
|---|---|---|---|---|
| NIC 1 | ens192 | {{ vm_network_eth0 }} | 3574 | Access |

## IP plan

| Purpose | Address |
|---|---|
| SNO node | {{ sno_node.ip }} |
| API DNS target | {{ sno_node.ip }} |
| Ingress DNS target | {{ sno_node.ip }} |
| Reserved API VIP, only for `sno_install_platform: vsphere` | {{ api_vip }} |
| Reserved Ingress VIP, only for `sno_install_platform: vsphere` | {{ ingress_vip }} |
| Gateway | {{ gateway }} |
| DNS | {{ ad_dns_server }} |

## DNS

| Record | Target |
|---|---|
| api.{{ cluster_name }}.{{ base_domain }} | {{ sno_node.ip }} |
| api-int.{{ cluster_name }}.{{ base_domain }} | {{ sno_node.ip }} |
| *.apps.{{ cluster_name }}.{{ base_domain }} | {{ sno_node.ip }} |
| {{ cluster_name }}-0.{{ cluster_name }}.{{ base_domain }} | {{ sno_node.ip }} |

## ACM managed bare-metal cluster IP plan

| Purpose | Address |
|---|---|
| Bare-metal API VIP | {{ bm_api_vip }} |
| Bare-metal Ingress VIP | {{ bm_ingress_vip }} |
| {{ bm_nodes[0].name }} OpenShift OS | {{ bm_nodes[0].ip }} |
| {{ bm_nodes[1].name }} OpenShift OS | {{ bm_nodes[1].ip }} |
| {{ bm_nodes[2].name }} OpenShift OS | {{ bm_nodes[2].ip }} |
| {{ site_b_nodes[0].name }} OpenShift OS | {{ site_b_nodes[0].ip }} |
| {{ site_b_nodes[1].name }} OpenShift OS | {{ site_b_nodes[1].ip }} |
| {{ site_b_nodes[2].name }} OpenShift OS | {{ site_b_nodes[2].ip }} |

## iDRAC/BMC IP plan

| Node | iDRAC/BMC IP |
|---|---|
| {{ bm_nodes[0].name }} | {{ bm_nodes[0].bmc_ip }} |
| {{ bm_nodes[1].name }} | {{ bm_nodes[1].bmc_ip }} |
| {{ bm_nodes[2].name }} | {{ bm_nodes[2].bmc_ip }} |
| {{ site_b_nodes[0].name }} | {{ site_b_nodes[0].bmc_ip }} |
| {{ site_b_nodes[1].name }} | {{ site_b_nodes[1].bmc_ip }} |
| {{ site_b_nodes[2].name }} | {{ site_b_nodes[2].bmc_ip }} |

The iDRAC/BMC IPs are intentionally separate from the OpenShift node OS IPs.

## SNO platform note

The default SNO install uses `sno_install_platform: none`, so the API and apps wildcard DNS records point to the single SNO node IP. The reserved VIPs are only used if you switch to `sno_install_platform: vsphere` and provide a real `vsphere_cluster` value.
