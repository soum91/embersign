#!/usr/bin/env python3
"""Write release notes with a changelog of commits since the previous release.

Outputs packages/RELEASE_NOTES.md (GitHub release body) and packages/CHANGES.txt
(one change per line, used for the FlareStore version description).
"""
import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = ROOT / "packages"
BUILD = os.environ.get("GITHUB_RUN_NUMBER", "0")
REPO = os.environ.get("GITHUB_REPOSITORY", "soum91/embersign")
SHA = os.environ.get("GITHUB_SHA", "HEAD")

FOOTER = """Re-sign the IPA using your current signing tool before installation. Apple Account features depend on Apple developer services and Anisette. Background refresh is best-effort and requires a reachable pairing tunnel. On-device pairing and the Apple Watch path are experimental. Built-in JIT uses StikJIT and needs a valid remote pairing record, LocalDevVPN, a compatible iOS/device and a development-signed target.

Complete engine source and original licenses are included in EmberSign-Source.tar.gz."""


def gh(path: str):
    out = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if out.returncode != 0:
        return None
    return json.loads(out.stdout)


def skip(subject: str) -> bool:
    s = subject.lower()
    return "[skip ci]" in s or s.startswith("merge ") or s.startswith("update flarestore feed")


def collect() -> tuple[list[str], str | None]:
    latest = gh(f"repos/{REPO}/releases/latest")
    prev = latest.get("tag_name") if isinstance(latest, dict) else None
    if not prev:
        return [], None
    compare = gh(f"repos/{REPO}/compare/{prev}...{SHA}")
    if not isinstance(compare, dict):
        return [], prev
    changes = []
    for commit in compare.get("commits", []):
        subject = commit["commit"]["message"].splitlines()[0].strip()
        if subject and not skip(subject) and subject not in changes:
            changes.append(subject)
    return changes, prev


def main() -> None:
    PACKAGES.mkdir(exist_ok=True)
    changes, prev = collect()
    lines = [f"EmberSign build {BUILD}", "", "## Changelog", ""]
    if changes:
        lines += [f"- {c}" for c in changes]
    else:
        lines.append("- Maintenance rebuild, no source changes since the previous release.")
    if prev:
        lines += ["", f"Full diff: https://github.com/{REPO}/compare/{prev}...{SHA[:7]}"]
    lines += ["", f"Install file: EmberSign-build-{BUILD}.ipa", "", FOOTER, ""]
    (PACKAGES / "RELEASE_NOTES.md").write_text("\n".join(lines))
    (PACKAGES / "CHANGES.txt").write_text("\n".join(changes) + ("\n" if changes else ""))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
