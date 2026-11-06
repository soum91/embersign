#!/usr/bin/env python3
"""Mandatory source contract for visible installed version/build labels in app UI."""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "version-ui-contract.json"


def main() -> int:
    errors = []
    try:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"ERROR: cannot read {MANIFEST.name}: {exc}", file=sys.stderr)
        return 1

    targets = data.get("targets")
    if data.get("schema_version") != 1 or not isinstance(targets, list) or not targets:
        print("ERROR: contract needs schema_version=1 and at least one app target", file=sys.stderr)
        return 1

    names = set()
    for target in targets:
        if not isinstance(target, dict):
            errors.append("Invalid target entry")
            continue
        name = target.get("name")
        evidence = target.get("evidence")
        if not isinstance(name, str) or not name.strip() or name in names:
            errors.append(f"Invalid or duplicate target name: {name!r}")
            continue
        names.add(name)
        if not isinstance(evidence, list) or not evidence:
            errors.append(f"{name}: no UI/source evidence declared")
            continue
        for item in evidence:
            if not isinstance(item, dict) or not isinstance(item.get("path"), str):
                errors.append(f"{name}: invalid evidence file")
                continue
            relative = Path(item["path"])
            path = (ROOT / relative).resolve()
            required = item.get("contains")
            if relative.is_absolute() or ROOT not in path.parents or not isinstance(required, list) or not required or any(not isinstance(s, str) or not s for s in required):
                errors.append(f"{name}: invalid path or required markers: {item['path']}")
                continue
            try:
                source = path.read_text(encoding="utf-8")
            except OSError:
                errors.append(f"{name}: source file missing: {relative}")
                continue
            for marker in required:
                if marker not in source:
                    errors.append(f"{name}: {relative} missing runtime/UI marker {marker!r}")

    if errors:
        for error in errors:
            print(f"::error::{error}", file=sys.stderr)
        print(f"FAILED: {len(errors)} installed-version contract check(s)", file=sys.stderr)
        return 1

    print(f"PASS: installed version/build contract for {len(targets)} app target(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
