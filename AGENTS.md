# App release contract (Codex and Claude)

This repository participates in Soumen's installed-version standard. These rules apply to all user-facing app targets and every future release.

1. Every installed app must visibly show its **actual installed version and build number** in an accessible app screen (prefer Settings > About; use an appropriate equivalent on TV, Watch, or desktop).
2. Read the values from the installed package metadata at runtime: iOS/watchOS Info.plist, Android PackageManager, Windows assembly/product version, or Tauri app version. Never display a hardcoded GitHub tag, feed version, or latest-available version as if installed.
3. Keep the UI version, packaged version/build, GitHub release, and app catalog feed consistent. Increment package version/build for each release as the platform and sideloader require.
4. The source evidence for every app target is listed in `version-ui-contract.json`. If UI code moves, update that manifest **and preserve equivalent visible functionality**. Do not remove, skip, or mark the installed-version gate non-blocking.
5. Before committing, run `python3 scripts/check_version_ui.py`. Release pipelines run this as a mandatory preflight. A failed version contract or failed compilation/package verification blocks publication. Other non-critical tests may remain non-blocking under the established release policy.
6. This is a source-level regression guard. CI compilation and, when feasible, actual device UI checks remain important. Add stronger tests when new platforms are introduced.

For changes requested by Soumen, work on the existing main/release path unless specifically asked otherwise. Do not create a PR or wait for confirmation merely to apply this convention.

## Mandatory factual release changelog

This rule applies to every GitHub Release, build release, prerelease, and future automated publishing workflow in this repository. Both Codex and Claude must follow it.

1. Every release must describe **real, specific changes since the previous release**, based on actual commits and the code diff. Explain what changed and where; include issue/commit references and any known limitations. Do not claim untested fixes or unsupported capabilities.
2. Never use generic filler such as "bug fixes", "performance improvements", "misc updates", "new features", or a copied/static note as the entire changelog. If a release only rebuilds the same source, label it as a **rebuild only** and state exactly what packaging, toolchain, signing, or artifact metadata changed. Do not invent application changes.
3. Keep the GitHub Release description and root `CHANGELOG.md` aligned. The `Factual release changelog` workflow audits actual source commits, adds evidence-linked notes to the release, and records the release in `CHANGELOG.md`. A failed audit is a release-policy failure that must be corrected, not ignored or disabled.
4. Release-producing workflows must prepare truthful release notes before publication. Treat the post-publication audit as an additional check, not permission to publish placeholders; never bypass the check or mark it non-blocking.
5. When a release contains user-facing assets, ensure version numbers and repo feeds also match the release. Existing installed-version rules remain in effect.

These instructions apply to changes by humans, GitHub Actions, Claude, Codex, and any other automation.
