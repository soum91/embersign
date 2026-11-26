# App release contract (Codex and Claude)

This repository participates in the owner's installed-version standard. These rules apply to all user-facing app targets and every future release.

1. Every installed app must visibly show its **actual installed version and build number** in an accessible app screen (prefer Settings > About; use an appropriate equivalent on TV, Watch, or desktop).
2. Read the values from the installed package metadata at runtime: iOS/watchOS Info.plist, Android PackageManager, Windows assembly/product version, or Tauri app version. Never display a hardcoded GitHub tag, feed version, or latest-available version as if installed.
3. Keep the UI version, packaged version/build, GitHub release, and app catalog feed consistent. Increment package version/build for each release as the platform and sideloader require.
4. The source evidence for every app target is listed in `version-ui-contract.json`. If UI code moves, update that manifest **and preserve equivalent visible functionality**. Do not remove, skip, or mark the installed-version gate non-blocking.
5. Before committing, run `python3 scripts/check_version_ui.py`. Release pipelines run this as a mandatory preflight. A failed version contract or failed compilation/package verification blocks publication. Other non-critical tests may remain non-blocking under the established release policy.
6. This is a source-level regression guard. CI compilation and, when feasible, actual device UI checks remain important. Add stronger tests when new platforms are introduced.

For changes requested by the repository owner, work on the existing main/release path unless specifically asked otherwise. Do not create a PR or wait for confirmation merely to apply this convention.

## Mandatory factual release changelog

This rule applies to every GitHub Release, build release, prerelease, and future automated publishing workflow in this repository. Both Codex and Claude must follow it.

1. Every release must describe **real, specific changes since the previous release**, based on actual commits and the code diff. Explain what changed and where; include issue/commit references and any known limitations. Do not claim untested fixes or unsupported capabilities.
2. Never use generic filler such as "bug fixes", "performance improvements", "misc updates", "new features", or a copied/static note as the entire changelog. If a release only rebuilds the same source, label it as a **rebuild only** and state exactly what packaging, toolchain, signing, or artifact metadata changed. Do not invent application changes.
3. Keep the GitHub Release description and root `CHANGELOG.md` aligned. The `Factual release changelog` workflow audits actual source commits, adds evidence-linked notes to the release, and records the release in `CHANGELOG.md`. A failed audit is a release-policy failure that must be corrected, not ignored or disabled.
4. Release-producing workflows must prepare truthful release notes before publication. Treat the post-publication audit as an additional check, not permission to publish placeholders; never bypass the check or mark it non-blocking.
5. When a release contains user-facing assets, ensure version numbers and repo feeds also match the release. Existing installed-version rules remain in effect.

These instructions apply to changes by humans, GitHub Actions, Claude, Codex, and any other automation.


## Universal diagnostic copy and export contract

Applies to Codex, Claude and all future diagnostic/debug/log reporting UI:

- Never ship a silent clipboard-only Copy button. After writing a report to the platform clipboard, immediately verify the full written text where APIs permit and display success or actionable failure. Do not present success on an unverified write.
- Every report must also offer an independent native Share action and Save as plain `.txt` file. On iOS, use the system share sheet and native Files picker (`fileExporter` or `UIDocumentPickerViewController`), not a custom file-path prompt. Allow selection of the complete report.
- Export the full diagnostics, including actual installed app/build, OS/device, and actionable failure/return codes. Redact credentials, access tokens, passwords and other secrets. Do not upload reports without consent.
- Test on a signed real device: Copy, paste into another app, Share and Save to Files, including error paths. If physical verification is unavailable, say so explicitly; a passing build is not evidence of clipboard success.
- Prefer one reusable diagnostic export component per application. Ensure future releases and newly created repositories retain this rule in both AGENTS.md and CLAUDE.md.


## Universal diagnostic export contract

Every diagnostic/log report requires Copy with clipboard read-back verification where supported and visible success/failure, native Share, native Save as `.txt` with Files picker (`fileExporter` or `UIDocumentPickerViewController` on iOS), and selectable full text fallback. No silent clipboard-only buttons. Include app/version, device/OS, actionable return codes and redact secrets. Test cross-app paste, Share, Save on a signed device; otherwise mark unverified. Preserve existing policies.


## Public attribution and owner privacy

Use `soum91` as the author, maintainer, developer, and publisher in all first-party metadata. Do not publish the owner's legal name, private email, or other personal identifiers in source, licenses, Sileo/FlareStore feeds, release assets, binary packages, generated docs, logs, or commits. Audit generated artifacts before publishing. Preserve legitimate third-party copyright notices. Existing bundle identifiers, app groups, and entitlements must not be silently changed, because doing so can break upgrades and stored data.


## Mandatory file-picker and import regression contract — all future apps

The owner has repeatedly encountered a critical bug: the iOS native Files picker opens and shows IPA files, but tapping a file does nothing and the app never receives/handles the selection. **Never consider a picker complete merely because it opens.** This applies to every future app, file type, importer, signer, export feature, and subsequent modification, not only IPA Studio or Watch installation.

1. Prefer a system-native picker (UIDocumentPickerViewController or SwiftUI .fileImporter) and properly declared, compatible content types. Support relevant real-world provider types and filename extensions (including .ipa / .tipa) without over-restrictive UTType filters that make visible files unselectable. Explicitly validate the selected extension and contents after selection, rather than assuming a provider-supplied UTType is accurate.
2. Prove the **complete event path**: tap an actual file in Files (On My iPhone, Downloads, and iCloud Drive as applicable) → receive its URL in the picker delegate/completion → dismiss the picker correctly → start and stop security-scoped access → copy the file into an app-owned staging directory *before releasing access* → validate and complete import → show success or an actionable error. The picker must never appear responsive while silently discarding the selection.
3. Keep the picked file alive through every asynchronous signing/import/extraction callback. Do not delete or overwrite staging files before downstream consumers finish. Avoid double-presented sheets, stale SwiftUI binding state, competing overlays, cancellation races, and onDisappear cleanup that can erase a file still being processed.
4. Support cancellation, re-opening the picker, selecting the same file twice, choosing a different file, files with spaces/parentheses in names, and cloud files that require downloading. Surface error details instead of doing nothing. Never mask a failed picker event as success.
5. Add deterministic tests for URL handling, accepted types/extensions, security-scoped copying, lifecycle and import callbacks wherever possible, **and real-device UI verification** on targeted OS versions. Minimum release test: successfully tap and import an IPA from Downloads, repeat a second import, try a non-IPA rejection, and verify both success and error feedback.
6. A passing compile or an open Files dialog **does not prove the importer works**. Do not claim a picker fixed or release-ready without an end-to-end on-device test; if hardware testing cannot be performed, label the behavior unverified and preserve a proven working picker path.
7. Whenever any new app is created or an import workflow is changed, carry forward this picker contract to its AGENTS.md and relevant tests. Do not regress an already-working native picker while implementing unrelated features.

This rule must be observed by Codex, Claude, GitHub Actions, and every development assistant working on the repository.

## Mandatory file picker / import policy (release-blocking)

Every file picker, browser, import, export, signing or upload workflow in this repository **MUST** comply with [MANDATORY_FILE_PICKER.md](https://github.com/soum91/tweaks/blob/main/MANDATORY_FILE_PICKER.md). This covers future apps and all platforms. Files must be selectable with a real tap, return to the caller, copy safely to app-owned storage, complete the import and give visible success/error. Real-device end-to-end testing is required before claiming success. Merely opening Files or compiling is insufficient. Preserve existing project policies. Codex and Claude must propagate this rule to new app repositories.
