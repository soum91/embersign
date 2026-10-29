#!/usr/bin/env python3
"""Publish only completed watch-support prereleases to the separate preview feed."""

from datetime import datetime, timezone
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def update_watch_feed(feed: dict, metadata: dict, repository: str, date: str) -> dict:
    version = str(metadata["version"])
    build = str(metadata["build"])
    size = int(metadata["size"])
    bundle_id = str(metadata["bundle_identifier"])
    if not build.isdecimal() or size <= 0 or bundle_id != "com.soum91.embersign":
        raise ValueError("Invalid experimental IPA metadata")
    if not version.startswith("0.2.1"):
        raise ValueError("Preview must have a version higher than the main feed's 0.2.0 release")
    if not repository or "/" not in repository:
        raise ValueError("Expected owner/repository")

    release_version = f"{version}.{build}"
    download = f"https://github.com/{repository}/releases/download/watch-preview-{build}/EmberSign.ipa"
    note = (
        "Experimental Apple Watch IPA inspection and signing-target report. "
        "Does not yet sign a Watch companion, provision Watch devices, "
        "or install an app onto Apple Watch."
    )
    item = {
        "version": release_version,
        "buildVersion": build,
        "date": date,
        "localizedDescription": note,
        "downloadURL": download,
        "size": size,
        "minOSVersion": "16.0",
    }
    apps = feed.setdefault("apps", [])
    if not apps:
        apps.append({
            "name": "EmberSign Watch Preview",
            "bundleIdentifier": bundle_id,
            "developerName": "soum91",
            "iconURL": "https://raw.githubusercontent.com/soum91/embersign/main/assets/icon.png",
            "category": "utilities",
            "tintColor": "#F27A35",
            "versions": [],
        })
    if len(apps) != 1 or apps[0].get("bundleIdentifier") != bundle_id:
        raise ValueError("Preview feed must contain only the EmberSign app")
    app = apps[0]
    previous = [
        entry for entry in app.get("versions", [])
        if not (str(entry.get("buildVersion")) == build and entry.get("version") == release_version)
    ]
    previous.append(item)
    previous.sort(key=lambda entry: tuple(int(p) for p in entry["version"].split(".")), reverse=True)
    app["versions"] = previous[:12]
    app.update({
        "subtitle": "Apple Watch IPA preflight (experimental)",
        "localizedDescription": note,
        "version": release_version,
        "versionDate": date,
        "versionDescription": note,
        "downloadURL": download,
        "size": size,
    })
    return feed


def main() -> None:
    path = ROOT / "watch-source.json"
    metadata = json.loads((ROOT / "packages/build-info.json").read_text(encoding="utf-8"))
    feed = json.loads(path.read_text(encoding="utf-8"))
    updated = update_watch_feed(
        feed, metadata,
        os.environ.get("GITHUB_REPOSITORY", "soum91/embersign"),
        datetime.now(timezone.utc).date().isoformat(),
    )
    path.write_text(json.dumps(updated, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Prepared Watch preview feed {metadata['version']}.{metadata['build']}")


if __name__ == "__main__":
    main()
