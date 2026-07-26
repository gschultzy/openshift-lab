#!/usr/bin/env python3
import argparse
import atexit
import ssl
import sys
import time
from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim


def get_args():
    p = argparse.ArgumentParser(description="Set a vSphere VM advanced setting / extraConfig value")
    p.add_argument("--hostname", required=True)
    p.add_argument("--username", required=True)
    p.add_argument("--password", required=True)
    p.add_argument("--datacenter", required=False)
    p.add_argument("--vm", required=True)
    p.add_argument("--key", required=True)
    p.add_argument("--value", required=True)
    p.add_argument("--insecure", action="store_true")
    return p.parse_args()


def wait_for_task(task, timeout=180):
    end = time.time() + timeout
    while time.time() < end:
        state = task.info.state
        if state == vim.TaskInfo.State.success:
            return
        if state == vim.TaskInfo.State.error:
            raise RuntimeError(task.info.error.msg if task.info.error else "vSphere task failed")
        time.sleep(1)
    raise TimeoutError("Timed out waiting for vSphere task")


def iter_objs(content, root, vimtype):
    view = content.viewManager.CreateContainerView(root, vimtype, True)
    try:
        for obj in view.view:
            yield obj
    finally:
        view.Destroy()


def main():
    args = get_args()
    ctx = None
    if args.insecure:
        ctx = ssl._create_unverified_context()
    si = SmartConnect(host=args.hostname, user=args.username, pwd=args.password, sslContext=ctx)
    atexit.register(Disconnect, si)
    content = si.RetrieveContent()

    root = content.rootFolder
    if args.datacenter:
        dcs = [dc for dc in iter_objs(content, content.rootFolder, [vim.Datacenter]) if dc.name == args.datacenter]
        if not dcs:
            raise SystemExit(f"No datacenter named {args.datacenter} found")
        root = dcs[0].vmFolder

    matches = [vm for vm in iter_objs(content, root, [vim.VirtualMachine]) if vm.name == args.vm]
    if not matches:
        raise SystemExit(f"No VM named {args.vm} found")
    if len(matches) > 1:
        raise SystemExit(f"Multiple VMs named {args.vm} found; rename or scope the search")
    vm = matches[0]

    current = {opt.key: opt.value for opt in (vm.config.extraConfig or [])}
    if str(current.get(args.key, "")) == args.value:
        print(f"{args.vm}: {args.key} already {args.value}")
        return

    spec = vim.vm.ConfigSpec()
    spec.extraConfig = [vim.option.OptionValue(key=args.key, value=args.value)]
    task = vm.ReconfigVM_Task(spec)
    wait_for_task(task)
    print(f"{args.vm}: set {args.key}={args.value}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
