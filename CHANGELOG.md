# Changelog

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

