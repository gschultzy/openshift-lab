#!/usr/bin/env python3
"""Disconnect all CD-ROM devices from a vSphere VM and clear ISO backing when possible."""
import argparse
import atexit
import ssl
import sys
from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim


def wait_for_task(task):
    while task.info.state in (vim.TaskInfo.State.running, vim.TaskInfo.State.queued):
        continue
    if task.info.state == vim.TaskInfo.State.error:
        raise task.info.error
    return task.info.result


def find_vm(content, name, datacenter=None):
    view = content.viewManager.CreateContainerView(content.rootFolder, [vim.VirtualMachine], True)
    try:
        matches = []
        for vm in view.view:
            if vm.name != name:
                continue
            if datacenter:
                parent = vm.parent
                dc_name = None
                while parent:
                    if isinstance(parent, vim.Datacenter):
                        dc_name = parent.name
                        break
                    parent = getattr(parent, 'parent', None)
                if dc_name != datacenter:
                    continue
            matches.append(vm)
        if not matches:
            raise RuntimeError(f"VM {name!r} not found" + (f" in datacenter {datacenter!r}" if datacenter else ""))
        if len(matches) > 1:
            raise RuntimeError(f"Multiple VMs named {name!r} found; pass --datacenter")
        return matches[0]
    finally:
        view.Destroy()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--hostname', required=True)
    parser.add_argument('--username', required=True)
    parser.add_argument('--password', required=True)
    parser.add_argument('--datacenter', default=None)
    parser.add_argument('--vm', required=True)
    parser.add_argument('--insecure', action='store_true')
    parser.add_argument('--power-off-if-needed', action='store_true')
    args = parser.parse_args()

    context = None
    if args.insecure:
        context = ssl._create_unverified_context()

    si = SmartConnect(host=args.hostname, user=args.username, pwd=args.password, sslContext=context)
    atexit.register(Disconnect, si)
    content = si.RetrieveContent()
    vm = find_vm(content, args.vm, args.datacenter)

    cdroms = [d for d in vm.config.hardware.device if isinstance(d, vim.vm.device.VirtualCdrom)]
    if not cdroms:
        print(f"No CD-ROM devices found on VM {args.vm}")
        return 0

    specs = []
    for cd in cdroms:
        new_cd = vim.vm.device.VirtualCdrom()
        new_cd.key = cd.key
        new_cd.controllerKey = cd.controllerKey
        new_cd.unitNumber = cd.unitNumber
        new_cd.connectable = vim.vm.device.VirtualDevice.ConnectInfo()
        new_cd.connectable.startConnected = False
        new_cd.connectable.connected = False
        new_cd.connectable.allowGuestControl = True
        new_cd.backing = vim.vm.device.VirtualCdrom.RemotePassthroughBackingInfo()
        new_cd.backing.deviceName = ""
        spec = vim.vm.device.VirtualDeviceSpec()
        spec.operation = vim.vm.device.VirtualDeviceSpec.Operation.edit
        spec.device = new_cd
        specs.append(spec)

    config = vim.vm.ConfigSpec()
    config.deviceChange = specs

    try:
        wait_for_task(vm.ReconfigVM_Task(config))
    except Exception as exc:
        if not args.power_off_if_needed or vm.runtime.powerState != vim.VirtualMachinePowerState.poweredOn:
            raise
        print(f"Online CD-ROM disconnect failed ({exc}); powering off VM to retry")
        wait_for_task(vm.PowerOffVM_Task())
        wait_for_task(vm.ReconfigVM_Task(config))
        wait_for_task(vm.PowerOnVM_Task())

    print(f"Disconnected {len(cdroms)} CD-ROM device(s) from VM {args.vm}")
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
