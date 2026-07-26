#!/usr/bin/env python3
"""Discover basic vSphere inventory names for this lab.

Outputs JSON containing datacenters, hosts, datastores, networks, folders,
and resource pools. Intended to help set Ansible variables exactly as vCenter
sees them.
"""
from __future__ import annotations

import argparse
import json
import ssl
import sys
from typing import Any

try:
    from pyVim.connect import SmartConnect, Disconnect
    from pyVmomi import vim
except Exception as exc:  # pragma: no cover
    print(json.dumps({"error": f"pyVmomi import failed: {exc}"}), file=sys.stderr)
    sys.exit(2)


def obj_path(obj: Any) -> str:
    names = []
    cur = obj
    while cur is not None and hasattr(cur, "name"):
        try:
            names.append(cur.name)
            cur = cur.parent
        except Exception:
            break
    return "/" + "/".join(reversed(names[:-1] if names and names[-1] == "rootFolder" else names))


def walk_folder(folder: Any, klass: Any | None = None):
    for child in getattr(folder, "childEntity", []) or []:
        if klass is None or isinstance(child, klass):
            yield child
        if isinstance(child, vim.Folder):
            yield from walk_folder(child, klass)
        elif isinstance(child, vim.Datacenter):
            if getattr(child, "vmFolder", None):
                yield from walk_folder(child.vmFolder, klass)
            if getattr(child, "hostFolder", None):
                yield from walk_folder(child.hostFolder, klass)


def rp_path(rp: vim.ResourcePool) -> str:
    parts = []
    cur = rp
    while isinstance(cur, vim.ResourcePool):
        parts.append(cur.name)
        cur = cur.parent
    return "/".join(reversed(parts))


def main() -> int:
    parser = argparse.ArgumentParser(description="Discover vSphere inventory names")
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--port", type=int, default=443)
    parser.add_argument("--validate-certs", action="store_true")
    args = parser.parse_args()

    ctx = None
    if not args.validate_certs:
        ctx = ssl._create_unverified_context()

    si = SmartConnect(
        host=args.hostname,
        user=args.username,
        pwd=args.password,
        port=args.port,
        sslContext=ctx,
    )
    try:
        content = si.RetrieveContent()
        result: dict[str, Any] = {
            "vcenter": args.hostname,
            "datacenters": [],
            "datastores": [],
            "hosts": [],
            "networks": [],
            "vm_folders": [],
            "resource_pools": [],
            "compute_resources": [],
        }

        for dc in content.rootFolder.childEntity:
            if not isinstance(dc, vim.Datacenter):
                continue
            dc_item = {"name": dc.name, "vm_folder": f"/{dc.name}/vm"}
            result["datacenters"].append(dc_item)
            result["vm_folders"].append(f"/{dc.name}/vm")

            for ds in getattr(dc, "datastore", []) or []:
                result["datastores"].append({"datacenter": dc.name, "name": ds.name})

            for net in getattr(dc, "network", []) or []:
                result["networks"].append({"datacenter": dc.name, "name": net.name})

            # Host folders can contain clusters, standalone compute resources, and sub-folders.
            for obj in walk_folder(dc.hostFolder):
                if isinstance(obj, vim.ComputeResource):
                    result["compute_resources"].append({
                        "datacenter": dc.name,
                        "name": obj.name,
                        "type": type(obj).__name__,
                    })
                    if getattr(obj, "resourcePool", None):
                        result["resource_pools"].append({
                            "datacenter": dc.name,
                            "compute_resource": obj.name,
                            "path": rp_path(obj.resourcePool),
                        })
                if isinstance(obj, vim.HostSystem):
                    result["hosts"].append({"datacenter": dc.name, "name": obj.name})

        print(json.dumps(result, indent=2, sort_keys=True))
    finally:
        Disconnect(si)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
