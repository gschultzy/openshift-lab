#!/usr/bin/env python3
"""Create or update a VMware Distributed Virtual Port Group.

Used by the lab automation when the ESXi host is attached to a vSphere
Distributed Switch rather than a standard vSwitch. This avoids relying on
ESXi esxcli standard-vswitch commands when only a DVS is present.
"""
import argparse
import atexit
import ssl
import sys
import time

from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim


def wait_for_task(task, timeout=180):
    start = time.time()
    while True:
        state = task.info.state
        if state == vim.TaskInfo.State.success:
            return task.info.result
        if state == vim.TaskInfo.State.error:
            raise RuntimeError(task.info.error.msg if task.info.error else "vSphere task failed")
        if time.time() - start > timeout:
            raise TimeoutError("Timed out waiting for vSphere task")
        time.sleep(2)


def view(content, vimtype):
    container = content.viewManager.CreateContainerView(content.rootFolder, vimtype, True)
    try:
        return list(container.view)
    finally:
        container.Destroy()


def find_by_name(content, vimtype, name):
    matches = [obj for obj in view(content, vimtype) if obj.name == name]
    return matches[0] if matches else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--datacenter", required=False)
    parser.add_argument("--switch-name", required=True)
    parser.add_argument("--portgroup-name", required=True)
    parser.add_argument("--vlan-id", required=True, type=int)
    parser.add_argument("--num-ports", default=128, type=int)
    parser.add_argument("--validate-certs", action="store_true")
    args = parser.parse_args()

    if not (0 <= args.vlan_id <= 4094):
        raise SystemExit("vlan-id must be between 0 and 4094")

    context = None if args.validate_certs else ssl._create_unverified_context()
    si = SmartConnect(host=args.hostname, user=args.username, pwd=args.password, sslContext=context)
    atexit.register(Disconnect, si)
    content = si.RetrieveContent()

    dvs_list = view(content, [vim.DistributedVirtualSwitch])
    dvs_names = [d.name for d in dvs_list]
    dvs = next((d for d in dvs_list if d.name == args.switch_name), None)
    if not dvs:
        print(f"ERROR: Distributed switch '{args.switch_name}' was not found.", file=sys.stderr)
        print(f"Available distributed switches: {dvs_names}", file=sys.stderr)
        return 2

    existing = find_by_name(content, [vim.dvs.DistributedVirtualPortgroup], args.portgroup_name)
    if existing:
        print(f"Distributed port group '{args.portgroup_name}' already exists on switch '{dvs.name}'.")
        return 0

    spec = vim.dvs.DistributedVirtualPortgroup.ConfigSpec()
    spec.name = args.portgroup_name
    spec.type = "earlyBinding"
    spec.numPorts = args.num_ports
    spec.defaultPortConfig = vim.dvs.VmwareDistributedVirtualSwitch.VmwarePortConfigPolicy()

    vlan_spec = vim.dvs.VmwareDistributedVirtualSwitch.VlanIdSpec()
    vlan_spec.inherited = False
    vlan_spec.vlanId = args.vlan_id
    spec.defaultPortConfig.vlan = vlan_spec

    task = dvs.AddDVPortgroup_Task([spec])
    wait_for_task(task)
    print(f"Created distributed port group '{args.portgroup_name}' on switch '{dvs.name}' with VLAN ID {args.vlan_id}.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
