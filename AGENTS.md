# App release contract (Codex and Claude)

This repository participates in Soumen's installed-version standard. These rules apply to all user-facing app targets and every future release.

1. Every installed app must visibly show its **actual installed version and build number** in an accessible app screen (prefer Settings > About; use an appropriate equivalent on TV, Watch, or desktop).
2. Read the values from the installed package metadata at runtime: iOS/watchOS Info.plist, Android PackageManager, Windows assembly/product version, or Tauri app version. Never display a hardcoded GitHub tag, feed version, or latest-available version as if installed.
3. Keep the UI version, packaged version/build, GitHub release, and app catalog feed consistent. Increment package version/build for each release as the platform and sideloader require.
4. The source evidence for every app target is listed in `version-ui-contract.json`. If UI code moves, update that manifest **and preserve equivalent visible functionality**. Do not remove, skip, or mark the installed-version gate non-blocking.
5. Before committing, run `python3 scripts/check_version_ui.py`. Release pipelines run this as a mandatory preflight. A failed version contract or failed compilation/package verification blocks publication. Other non-critical tests may remain non-blocking under the established release policy.
6. This is a source-level regression guard. CI compilation and, when feasible, actual device UI checks remain important. Add stronger tests when new platforms are introduced.

For changes requested by Soumen, work on the existing main/release path unless specifically asked otherwise. Do not create a PR or wait for confirmation merely to apply this convention.
