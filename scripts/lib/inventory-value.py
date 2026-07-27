#!/usr/bin/env python3
"""Read a value from inventories/env/group_vars/all/main.yml.

This helper intentionally reads only values explicitly stored in main.yml. It does
not evaluate Jinja expressions. Shell scripts use it for environment-specific
scalar values and structured lists that are defined directly in the inventory.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError as exc:  # pragma: no cover - runtime guard
    raise SystemExit(
        "PyYAML is required. Activate .venv or run scripts/bootstrap-ubuntu-24.04.sh."
    ) from exc


def get_path(data: Any, dotted_path: str) -> Any:
    value = data
    for part in dotted_path.split("."):
        if isinstance(value, list):
            try:
                value = value[int(part)]
            except (ValueError, IndexError) as exc:
                raise KeyError(dotted_path) from exc
        elif isinstance(value, dict) and part in value:
            value = value[part]
        else:
            raise KeyError(dotted_path)
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", help="Dotted variable path, for example sno_node.ip")
    parser.add_argument(
        "--file",
        default="inventories/env/group_vars/all/main.yml",
        help="Inventory main.yml path",
    )
    parser.add_argument("--default", default=None)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    source = Path(args.file)
    if not source.is_file():
        print(f"Inventory variables file not found: {source}", file=sys.stderr)
        return 2

    data = yaml.safe_load(source.read_text(encoding="utf-8")) or {}
    try:
        value = get_path(data, args.path)
    except KeyError:
        if args.default is None:
            print(f"Variable not found in {source}: {args.path}", file=sys.stderr)
            return 3
        value = args.default

    if args.json or isinstance(value, (dict, list)):
        print(json.dumps(value))
    elif isinstance(value, bool):
        print("true" if value else "false")
    elif value is None:
        print("")
    else:
        print(value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
