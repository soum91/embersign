# Changelog

## Unreleased

- Recognize both legacy `Watch/` and modern `PlugIns/` companions in Sources and Apps update downloads. Validate companion metadata before routing to per-target iPhone + Watch provisioning and installation.
- Show tracked Watch apps in Apps with installed version/build, transfer progress, and a single update/re-sign action. Route existing Library Install, Sign, and Re-sign actions for embedded Watch packages through that same pipeline instead of installing only the host.
- Correct empty or inherited WristPane-default repo URLs for WatchLink installs so repo refreshes query the WatchLink feed. Preserve explicitly selected custom repos.
- Add archive layout regression cases. Real-device repo updates and Watch installs remain unverified.

## [v0.2.1-build.95] - 2026-11-15

## Verified changes since v0.2.1-build.91

- Restore compatible Xcode dependency caches for signing-flow builds ([`210daf94`](https://github.com/soum91/embersign/commit/210daf9494ec0ddf23fb8582088a8658f2e73b76); `.github/workflows/build.yml`)
- Disambiguate Developer Portal AppGroup from EmberSign widget storage ([`af41d664`](https://github.com/soum91/embersign/commit/af41d66417e1e053f4ded5aaa9b110eb50c571a1); `overrides/Feather/Ember/EmberAccountManager.swift`)
- Snapshot existing WatchLink group memberships after obtaining a certificate ([`3595cfa7`](https://github.com/soum91/embersign/commit/3595cfa745ecbd352f625ff0632c7f214cf5f4ad); `overrides/Feather/Ember/EmberAccountManager.swift`)
- Provision WatchLink probe App Group and verify signed entitlements ([`450bf0a9`](https://github.com/soum91/embersign/commit/450bf0a976fd51513500543cf5e210b3f7785b3e); `.github/workflows/build.yml`, `Tests/WatchLinkProbeTests.swift`, `overrides/Feather/Ember/Core/EmberWatchLinkProbe.swift`, and 2 more)

[Inspect exact code changes](https://github.com/soum91/embersign/compare/v0.2.1-build.91...v0.2.1-build.95)

## Unreleased

- Provision a stable, team-specific disposable App Group for the exact WatchLink iPhone and Watch bundle IDs. Enable the capability, preserve existing authorized group memberships, assign the group, and download fresh per-target profiles. Other Watch apps retain their existing provisioning flow.
- Stop WatchLink signing if Apple omits the probe group; inspect the resulting signed entitlement slot in every executable architecture before packaging to catch groups stripped by the signer. This checks consistency, not cryptographic validity or sandbox escape support.
- Add mandatory fixture tests for profile authorization, package targeting, thin/fat executable entitlement retention, and malformed metadata. Physical Watch execution remains unverified; multi-pairing is not implemented.

## [v0.2.1-build.91] - 2026-11-15

## Verified changes since v0.2.1-build.89

- Install and update Apple Watch apps straight from Sources repos ([`ee7d9c04`](https://github.com/soum91/embersign/commit/ee7d9c048afe11fb2d30b63d19d4613499ce8370); `Tests/test_watch_native_safety.py`, `overrides/Feather/Ember/EmberWatchSourceRouter.swift`, `overrides/Feather/Ember/EmberWatchSupportView.swift`, and 1 more)
- Update Apple Watch apps from their repo automatically ([`e2b974c0`](https://github.com/soum91/embersign/commit/e2b974c0071ae57f5c5c2f45160e186fab942a1a); `Tests/test_watch_native_safety.py`, `overrides/Feather/Ember/EmberWatchSupportView.swift`)

[Inspect exact code changes](https://github.com/soum91/embersign/compare/v0.2.1-build.89...v0.2.1-build.91)

## [v0.2.1-build.89] - 2026-11-14

## Verified changes since v0.2.1-build.88

- Seal nested Watch bundles after writing their provisioning profile ([`2ab28775`](https://github.com/soum91/embersign/commit/2ab287754e54b66d1706e70e5015938a874aed15); `Tests/test_watch_native_safety.py`, `scripts/prepare.py`)

[Inspect exact code changes](https://github.com/soum91/embersign/compare/v0.2.1-build.88...v0.2.1-build.89)

## [v0.2.1-build.88] - 2026-11-14

## Verified changes since v0.2.1-build.87

- Keep embedded profiles when signing the Apple Watch and extensions ([`e3215594`](https://github.com/soum91/embersign/commit/e321559415f3307b9466ad3e5a0b7865ba78589f); `Tests/test_watch_native_safety.py`, `overrides/Feather/Ember/EmberIOSExtensions.swift`, `overrides/Feather/Ember/EmberWatchSupportView.swift`)

[Inspect exact code changes](https://github.com/soum91/embersign/compare/v0.2.1-build.87...v0.2.1-build.88)

## [v0.2.1-build.87] - 2026-11-14

## Verified changes since v0.2.1-build.86

- Fix "Missing Pairing (-7001)" on local installs when LocalDevVPN is not 10.7.0.1 ([`07221152`](https://github.com/soum91/embersign/commit/0722115222347902b31dc3e117638a281f8856a9); `Tests/test_watch_native_safety.py`, `scripts/prepare.py`)

[Inspect exact code changes](https://github.com/soum91/embersign/compare/v0.2.1-build.86...v0.2.1-build.87)

## [v0.2.1-build.86] - 2026-11-14

## Verified changes since v0.2.1-build.85

- Fix Watch signing crash: Zsign called a nil completion block ([`1f921706`](https://github.com/soum91/embersign/commit/1f9217067cccb31fee2922b2ca2b02572c6c9b1b); `Tests/test_watch_native_safety.py`, `overrides/Feather/Ember/EmberIOSExtensions.swift`, `overrides/Feather/Ember/EmberWatchSupportView.swift`, and 1 more)

[Inspect exact code changes](https://github.com/soum91/embersign/compare/v0.2.1-build.85...v0.2.1-build.86)

## [v0.2.1-build.85] - 2026-11-14

## Verified changes since v0.2.1-build.84

- Fix Apple session expiry (1100), native Watch crash, and opaque install errors ([`86b83e31`](https://github.com/soum91/embersign/commit/86b83e3121bb4cbc9d5392c5e2f03d9b24a2aff9); `Tests/test_account_session.py`, `Tests/test_watch_native_safety.py`, `overrides/Feather/Ember/EmberAccountManager.swift`, and 2 more)

[Inspect exact code changes](https://github.com/soum91/embersign/compare/v0.2.1-build.84...v0.2.1-build.85)

## [v0.2.1-build.84] - 2026-11-10

## Verified changes since v0.2.1-build.82

- Remove owner personal-name attribution ([`f923698f`](https://github.com/soum91/embersign/commit/f923698f3850700fbd43aa3361b4f55f6b061dc2); `pairing-native/LICENSE`)

[Inspect exact code changes](https://github.com/soum91/embersign/compare/v0.2.1-build.82...v0.2.1-build.84)

This log records verified, release-specific changes. The [Factual release changelog](.github/workflows/release-changelog.yml) GitHub Action adds entries based on the actual commits between published releases. Entries are not fabricated for older versions that have not been audited.

