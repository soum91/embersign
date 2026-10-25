#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ipa = ROOT / "packages/EmberSign.ipa"
lock = json.loads((ROOT / "upstream.lock.json").read_text())
with zipfile.ZipFile(ipa) as archive:
    assert "Payload/EmberSign.app/Info.plist" in archive.namelist()
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
metadata = {
    "version": lock["version"], "build": os.environ.get("GITHUB_RUN_NUMBER", "1"),
    "bundle_identifier": lock["bundle_identifier"], "upstream_commit": lock["commit"],
    "sha256": digest, "size": ipa.stat().st_size,
    "signing": "ad-hoc; requires personal re-signing",
    "jit_activation": "StikDebug handoff or user-configured SideJITServer",
    "apple_account_login": True,
}
(ROOT / "packages/build-info.json").write_text(json.dumps(metadata, indent=2) + "\n")
(ROOT / "packages/EmberSign.ipa.sha256").write_text(f"{digest}  EmberSign.ipa\n")
