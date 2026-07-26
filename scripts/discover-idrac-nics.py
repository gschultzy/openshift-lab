#!/usr/bin/env python3
"""Discover Dell iDRAC host NIC MACs/link state through Redfish.

By default this is read-only and prints a compact table. With
--auto-fill-placeholders and --write-inventory, it also updates placeholder
boot_mac values like CHANGE_ME_B09_33_BOOT_NIC_MAC in the inventory file.

Selection logic is intentionally conservative:
- prefer the 25G host NIC named NIC.Integrated.1-1-1 / Integrated Port 1
- fall back to Network Port View port 1 at 10G/25G/100G and link up
- never use the 1G iDRAC Manager Ethernet Interface
- never use Fibre Channel / WWPN-looking addresses
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import ssl
import sys
import urllib.request
from pathlib import Path
from typing import Any

MAC_RE = re.compile(r"^[0-9A-F]{2}(:[0-9A-F]{2}){5}$")


def get_json(host: str, path: str, user: str, password: str, timeout: int = 15) -> Any | None:
    url = f"https://{host}{path}"
    req = urllib.request.Request(url)
    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    req.add_header("Authorization", f"Basic {token}")
    req.add_header("Accept", "application/json")
    ctx = ssl._create_unverified_context()
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8", "replace"))
    except Exception:
        return None


def member_ids(obj: Any) -> list[str]:
    if not isinstance(obj, dict):
        return []
    out: list[str] = []
    for m in obj.get("Members", []) or []:
        if isinstance(m, dict) and m.get("@odata.id"):
            out.append(m["@odata.id"])
    return out


def nested_odata_ids(obj: Any) -> list[str]:
    ids: list[str] = []

    def walk(x: Any):
        if isinstance(x, dict):
            oid = x.get("@odata.id")
            if isinstance(oid, str) and any(k in oid.lower() for k in ["network", "ethernet", "adapter", "port", "function"]):
                ids.append(oid)
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for i in x:
                walk(i)

    walk(obj)
    return ids


def macs_from(obj: dict[str, Any]) -> list[str]:
    keys = ["MACAddress", "PermanentMACAddress", "CurrentMACAddress"]
    macs: list[str] = []
    for k in keys:
        v = obj.get(k)
        if isinstance(v, str) and ":" in v:
            macs.append(v.upper())
    for k in ["AssociatedNetworkAddresses", "IPv4Addresses"]:
        v = obj.get(k)
        if isinstance(v, list):
            for item in v:
                if isinstance(item, str) and ":" in item and len(item) >= 12:
                    macs.append(item.upper())
    seen: set[str] = set()
    out: list[str] = []
    for m in macs:
        if m not in seen:
            out.append(m)
            seen.add(m)
    return out


def collect_for_host(host: str, user: str, password: str) -> list[dict[str, Any]]:
    roots = [
        "/redfish/v1/Systems/System.Embedded.1/EthernetInterfaces",
        "/redfish/v1/Systems/System.Embedded.1/NetworkInterfaces",
        "/redfish/v1/Chassis/System.Embedded.1/NetworkAdapters",
        "/redfish/v1/Managers/iDRAC.Embedded.1/EthernetInterfaces",
    ]
    to_fetch: list[str] = []
    seen: set[str] = set()
    for root in roots:
        data = get_json(host, root, user, password)
        if data is None:
            continue
        to_fetch.extend(member_ids(data))
        to_fetch.extend(nested_odata_ids(data))
    records: list[dict[str, Any]] = []
    depth = 0
    while to_fetch and depth < 250:
        depth += 1
        path = to_fetch.pop(0)
        if path in seen:
            continue
        seen.add(path)
        data = get_json(host, path, user, password)
        if data is None or not isinstance(data, dict):
            continue
        to_fetch.extend([p for p in member_ids(data) if p not in seen])
        to_fetch.extend([p for p in nested_odata_ids(data) if p not in seen])
        macs = macs_from(data)
        if macs:
            records.append(
                {
                    "path": path,
                    "id": data.get("Id", ""),
                    "name": data.get("Name", ""),
                    "description": data.get("Description", ""),
                    "macs": macs,
                    "link": data.get("LinkStatus", data.get("Status", {}).get("State", "")),
                    "health": data.get("Status", {}).get("Health", ""),
                    "speed": data.get("CurrentLinkSpeedMbps", data.get("SpeedMbps", data.get("LinkSpeedMbps", ""))),
                    "port": data.get("PhysicalPortNumber", data.get("PortId", data.get("PortNumber", ""))),
                }
            )
    uniq: list[dict[str, Any]] = []
    seenkeys: set[tuple[str, tuple[str, ...]]] = set()
    for r in records:
        key = (str(r["path"]), tuple(r["macs"]))
        if key not in seenkeys:
            uniq.append(r)
            seenkeys.add(key)
    return uniq


def is_placeholder(value: str) -> bool:
    return "CHANGE_ME" in value.upper() or not MAC_RE.match(value.upper())


def good_host_macs(record: dict[str, Any]) -> list[str]:
    # Avoid iDRAC management and fibre channel/WWPN-looking addresses.
    text = " ".join(str(record.get(k, "")) for k in ["path", "id", "name", "description"]).lower()
    if "manager" in text or "idrac" in text:
        return []
    return [m for m in record.get("macs", []) if MAC_RE.match(str(m).upper())]


def link_is_up(record: dict[str, Any]) -> bool:
    return str(record.get("link", "")).lower() in {"up", "linkup", "enabled"}


def speed_int(record: dict[str, Any]) -> int:
    try:
        return int(str(record.get("speed") or "0"))
    except ValueError:
        return 0


def record_text(record: dict[str, Any]) -> str:
    return " ".join(str(record.get(k, "")) for k in ["path", "id", "name", "description", "port"]).lower()


def select_boot_mac(records: list[dict[str, Any]], preferred_port: str = "1") -> tuple[str | None, dict[str, Any] | None, str]:
    candidates = [r for r in records if link_is_up(r) and speed_int(r) >= 10000 and good_host_macs(r)]
    if not candidates:
        return None, None, "no link-up host NIC candidate at >=10Gbps"

    # Strong preference for Dell System EthernetInterface ID for Integrated NIC 1 Port 1.
    integrated_id = f"nic.integrated.1-{preferred_port}-1"
    for r in candidates:
        if integrated_id in record_text(r):
            return good_host_macs(r)[0], r, f"matched {integrated_id}"

    # Next prefer Network Port View PhysicalPortNumber/PortId == preferred_port.
    for r in candidates:
        if str(r.get("port", "")) == preferred_port:
            return good_host_macs(r)[0], r, f"matched physical port {preferred_port}"

    # Last fallback: first fastest link-up host NIC.
    candidates.sort(key=speed_int, reverse=True)
    r = candidates[0]
    return good_host_macs(r)[0], r, "fallback first fastest link-up host NIC"


def replace_node_boot_mac(text: str, node_name: str, old_value: str, new_value: str) -> tuple[str, bool]:
    # First try a simple placeholder replacement, which preserves formatting/comments.
    if old_value and old_value in text:
        return text.replace(old_value, new_value), True

    # Fallback: replace boot_mac within the YAML block for this node.
    pattern = re.compile(
        rf"(?ms)(^\s*-\s+name:\s+{re.escape(node_name)}\s*$.*?^\s+boot_mac:\s*)\"?[^\"\n]+\"?",
        re.MULTILINE,
    )
    new_text, n = pattern.subn(rf'\1"{new_value}"', text, count=1)
    return new_text, n > 0


def update_inventory(path: Path, replacements: list[tuple[str, str, str]]) -> bool:
    text = path.read_text()
    changed = False
    for node_name, old_value, new_value in replacements:
        text, did = replace_node_boot_mac(text, node_name, old_value, new_value)
        changed = changed or did
    if changed:
        backup = path.with_suffix(path.suffix + ".bak")
        backup.write_text(path.read_text())
        path.write_text(text)
    return changed


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--nodes-json", required=True, help="JSON list with node name/bmc_ip/boot_mac/ip fields")
    ap.add_argument("--user", required=True)
    ap.add_argument("--password-env", default="IDRAC_PASSWORD")
    ap.add_argument("--auto-fill-placeholders", action="store_true", help="auto-select boot_mac values for CHANGE_ME placeholders")
    ap.add_argument("--write-inventory", help="inventory group_vars/all/main.yml path to update when auto-fill is enabled")
    ap.add_argument("--preferred-port", default="1", help="preferred physical host NIC port, default 1")
    args = ap.parse_args()

    password = os.environ.get(args.password_env)
    if not password:
        print(f"ERROR: environment variable {args.password_env} is not set", file=sys.stderr)
        return 2

    nodes = json.loads(args.nodes_json)
    replacements: list[tuple[str, str, str]] = []

    for node in nodes:
        if not node.get("enabled", True):
            continue
        print(
            f"\n# {node.get('name')}  iDRAC={node.get('bmc_ip')}  "
            f"current boot_mac={node.get('boot_mac')}  target_ip={node.get('ip')}"
        )
        recs = collect_for_host(str(node.get("bmc_ip")), args.user, password)
        if not recs:
            print("  No NIC MACs found from Redfish candidate endpoints")
            continue
        print("  Link       Speed     Port/Id                         MAC(s)                         Redfish path/name")
        print("  ---------  --------  ------------------------------  -----------------------------  -----------------")
        for r in recs:
            link = str(r.get("link") or "")[:9]
            speed = str(r.get("speed") or "")[:8]
            port = str(r.get("port") or r.get("id") or "")[:30]
            mac = ",".join(r["macs"])
            name = str(r.get("name") or r.get("description") or r.get("path"))[:80]
            print(f"  {link:<9}  {speed:<8}  {port:<30}  {mac:<29}  {name}")

        current = str(node.get("boot_mac", "")).upper()
        matches = [r for r in recs if current and current in r["macs"]]
        if matches:
            m = matches[0]
            print(f"  MATCH: current boot_mac {current} found on {m.get('name') or m.get('id')} link={m.get('link')} speed={m.get('speed')}")

        selected_mac, selected_record, reason = select_boot_mac(recs, args.preferred_port)
        if selected_mac:
            print(
                f"  AUTO-CANDIDATE: {selected_mac}  # {reason}; "
                f"{selected_record.get('name') or selected_record.get('id')} port={selected_record.get('port')} speed={selected_record.get('speed')}"
            )

        link_up = [r for r in recs if link_is_up(r)]
        if link_up:
            print("  Link-up MAC candidates:")
            for r in link_up:
                for mac in r["macs"]:
                    print(f"    - {mac}  # {r.get('name') or r.get('id')} {r.get('port')} {r.get('speed')}")

        if args.auto_fill_placeholders and is_placeholder(current):
            if selected_mac:
                replacements.append((str(node.get("name")), str(node.get("boot_mac", "")), selected_mac))
                print(f"  AUTO-FILL: will set {node.get('name')} boot_mac to {selected_mac}")
            else:
                print(f"  AUTO-FILL: could not safely select a boot_mac for {node.get('name')}: {reason}")

    if args.auto_fill_placeholders:
        if not args.write_inventory:
            print("ERROR: --write-inventory is required with --auto-fill-placeholders", file=sys.stderr)
            return 2
        if replacements:
            inv = Path(args.write_inventory)
            changed = update_inventory(inv, replacements)
            if changed:
                print(f"\nUPDATED_INVENTORY: {inv}")
                for node_name, _old, new in replacements:
                    print(f"  {node_name}: boot_mac={new}")
            else:
                print(f"\nNO_INVENTORY_CHANGE: replacements were found but {inv} was not updated")
                return 1
        else:
            print("\nNO_INVENTORY_CHANGE: no placeholder boot_mac values needed updating")

    print("\n# NOTE: iDRAC can tell you the hardware MAC/link state, but not always the RHCOS Linux interface name.")
    print("# For these R6525 Broadcom ports it is commonly eno33np0 for Integrated NIC 1 Port 1.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
