#!/usr/bin/env python3
"""Publish the latest completed IPA in the FlareStore/AltStore source feed."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP_DESCRIPTION = (
    "EmberSign signs IPAs using imported certificates or Apple Account provisioning, "
    "supports multiple saved Apple Accounts, compatible tweak injection, pairing-file "
    "management, JIT preparation, paired-device app inventory, best-effort app refresh, "
    "and error diagnostics with online lookup. Apple services and background refresh "
    "require device testing; a pairing tunnel is needed for installed-app inventory."
)


def update_feed(feed: dict, metadata: dict, repository: str, release_date: str) -> dict:
    release_version = str(metadata["version"])
    build = str(metadata["build"])
    bundle_id = str(metadata["bundle_identifier"])
    size = int(metadata["size"])
    if not build.isdecimal() or size <= 0:
        raise ValueError("Build number must be numeric and IPA size must be positive")
    if not repository or "/" not in repository:
        raise ValueError("Expected owner/repository")

    apps = [app for app in feed.get("apps", []) if app.get("bundleIdentifier") == bundle_id]
    if len(apps) != 1:
        raise ValueError(f"Expected one feed app for {bundle_id}, found {len(apps)}")
    app = apps[0]
    version = f"{release_version}.{build}"
    download = f"https://github.com/{repository}/releases/download/v{release_version}-build.{build}/EmberSign.ipa"
    notes = (
        f"EmberSign {release_version} build {build}: Apple Accounts, signing and provisioning, "
        "paired-device app inventory, quota estimates, refresh controls, JIT tools, and diagnostics."
    )
    entry = {
        "version": version,
        "buildVersion": build,
        "date": release_date,
        "localizedDescription": notes,
        "downloadURL": download,
        "size": size,
        "minOSVersion": "16.0",
    }
    other_versions = [
        item for item in app.get("versions", [])
        if not (str(item.get("buildVersion")) == build and item.get("downloadURL") == download)
    ]
    other_versions.append(entry)
    def sort_key(item: dict):
        parts = tuple(int(p) if p.isdecimal() else 0 for p in str(item.get("version", "0")).split("."))
        return parts, int(str(item.get("buildVersion", "0")))
    app["versions"] = sorted(other_versions, key=sort_key, reverse=True)
    app.update({
        "subtitle": "Apple Accounts, IPA signing and JIT tools",
        "localizedDescription": APP_DESCRIPTION,
        "version": version,
        "versionDate": release_date,
        "versionDescription": notes,
        "downloadURL": download,
        "size": size,
    })
    return feed


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=ROOT / "source.json")
    parser.add_argument("--metadata", type=Path, default=ROOT / "packages/build-info.json")
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", "soum91/embersign"))
    parser.add_argument("--version")
    parser.add_argument("--build")
    parser.add_argument("--size", type=int)
    parser.add_argument("--date", default=datetime.now(timezone.utc).date().isoformat())
    args = parser.parse_args()

    if args.version is not None or args.build is not None or args.size is not None:
        if args.version is None or args.build is None or args.size is None:
            parser.error("--version, --build and --size must be given together")
        metadata = {
            "version": args.version, "build": args.build,
            "size": args.size, "bundle_identifier": "com.soum91.embersign",
        }
    else:
        metadata = json.loads(args.metadata.read_text(encoding="utf-8"))

    feed = json.loads(args.source.read_text(encoding="utf-8"))
    updated = update_feed(feed, metadata, args.repository, args.date)
    args.source.write_text(json.dumps(updated, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"FlareStore feed now advertises {metadata['version']} build {metadata['build']}")


if __name__ == "__main__":
    main()
