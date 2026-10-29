# EmberSign

An iOS 16+ app for signing and customizing IPAs on device, managing pairing files, and requesting JIT activation.

## Features

- On-device signing with an imported `.p12` certificate and `.mobileprovision` profile.
- Apple Account sign-in with trusted-device, SMS, or voice 2FA through SideSign and configurable Anisette, with multiple sessions stored separately in the device Keychain.
- Personal Team quota, certificate, App ID, provisioning-profile, and registered-device inventory for every saved account/team.
- One-tap Apple Account provisioning from the signing screen, including device registration, App ID creation, certificate creation, and a fresh app-specific development profile.
- Paired-device app inventory showing bundle ID, version/build, signer, team/account match, application identifier, and JIT entitlement.
- Uninstall-only and uninstall-plus-portal-record cleanup actions. Apple still controls when Personal Team quota becomes reusable.
- Automatic re-sign/reinstall attempts for apps provisioned through EmberSign, with a manual refresh action and iOS background-fetch support.
- Structured error history with Apple/SideSign domain and code, local recovery guidance, SideStore issue lookup, and wider web search.
- IPA import, app library, signing options, installation, expiry display, and signed IPA export.
- Compatible `.dylib`, `.deb`, framework, and bundle injection before signing, inherited from Feather.
- A **Prepare for JIT** signing switch that validates the selected development profile before adding debugger permission.
- Pairing-file import, structural validation, atomic replacement, removal, and export through Files. Lockdown and remote-pairing formats remain distinct and are exported without altering their contents.
- **Enable JIT** in a signed app's context menu and a dedicated JIT tools screen. Built-in StikJIT prepares the developer image, launches the selected target and attaches the debugger directly from EmberSign (iOS 17.4+).
- StikDebug activation handoff for supported devices, plus a configurable SideJITServer client with device discovery and explicit server-reported status.
- A stable bundle identifier, `com.soum91.embersign`, and increasing build numbers. Updates must still be signed with the same identity and installed bundle identifier to retain app data.

## Current limits

### Experimental Apple Watch branch

The `watch-support` branch adds an Apple Watch preflight screen under Tools. It can inspect an imported IPA for modern `PlugIns/*.app` and older `Watch/*.app` companions, list the Watch app and WidgetKit signing targets, and identify the separate profiles required for each target. This is **read-only inspection**, not Watch signing or Watch installation. The branch publishes separate **prereleases** and the standalone FlareStore-compatible feed below. It never updates the main-branch release or main FlareStore feed. The companion signing engine, Apple Watch device registration, and watchOS installation transport still need implementation and physical Watch testing. Never install a Watch IPA signed with an iPhone-only profile and expect its complications to work.

Experimental FlareStore source: `https://raw.githubusercontent.com/soum91/embersign/watch-support/watch-source.json`.
This source advertises an app only after its IPA was built and published as a GitHub prerelease. Preview builds use a newer version number than `main` so the user's existing signed EmberSign installation can recognize an update, provided it is re-signed with the same installed signing identity.

Apple Account authentication and provisioning depend on Apple's private developer-service behavior and Anisette. Apple can change either flow without notice, public Anisette services can be unavailable, and repeated failed sign-ins can be rate-limited. EmberSign never stores the Apple Account password. Auth sessions and generated signing keys are stored in the iOS Keychain.

Automatic refresh is best-effort. iOS decides when background fetch runs, and reinstallation requires the matching pairing file and a reachable LocalDevVPN tunnel. Open EmberSign periodically and use **Refresh tracked apps now** if iOS has not granted background time.

A paired tunnel lets EmberSign query Apple's installation service for user-app metadata. Without a working pairing tunnel, EmberSign cannot enumerate all installed apps. An account can be matched when the app exposes a team identifier that belongs to one of the signed-in development teams.

Deleting a provisioning profile or App ID does not guarantee immediate quota recovery. Personal Team App IDs, devices, profiles, and the three-app per-device limit are enforced by Apple. Revoking a certificate can make every app signed with it stop launching.

Preparing entitlements is not the same as activating JIT. A distribution profile cannot be turned into a development profile by changing a switch. Built-in StikJIT requires iOS 17.4+, Developer Mode, a compatible remote-pairing record, LocalDevVPN, and a development-signed target with `get-task-allow`. On iOS 26+ the target JIT allocator may need to implement StikJIT's universal breakpoint protocol; debugger attachment alone is insufficient on devices with TXM/SPTM. Built-in activation is newly implemented and still needs real-device verification.

EmberSign can export an imported pairing record. On iOS 27 it can experimentally generate a new remote-pairing record on the device using Developer Mode approval, without a computer. This workflow is not yet verified on physical hardware. Earlier iOS versions generally require an existing pairing file from a trusted computer. EmberSign cannot read other apps' private pairing credentials or convert Lockdown records into remote-pairing records.

Tweak injection applies to the IPA being signed. Jailbreak-only services and system-wide tweaks are not supported. Use an unencrypted IPA compatible with the tweak and device architecture.

## Install and use

FlareStore/AltStore-compatible feed: `https://raw.githubusercontent.com/soum91/embersign/main/source.json`.
The release workflow updates this feed only after the IPA has been published successfully.
The feed version includes the build number (for example `0.2.0.14`), matching the installed app version.
If a client caches an older entry, refresh the source in that client.

1. Download `EmberSign.ipa` from Releases. The CI IPA is ad-hoc signed and must be re-signed using your existing signing tool before installing it.
2. In Tools > Apple Accounts, sign in and complete 2FA, or import an existing signing certificate/profile from Settings or Tools.
3. In Apps, import an IPA and choose Sign. Choose **Provision with Apple Account** to create a fresh identity for that bundle ID, or select an imported certificate. Add tweaks before signing. To prepare a compatible app for JIT, enable Prepare for JIT and use a development profile.
4. Install or export the signed IPA.
5. In Tools > Pairing file, import your trusted pairing record. Export a copy to Files when you need to import it into Reynard or another compatible tool.
6. For built-in JIT activation, save a compatible remote pairing record in Tools > Pairing file (on iOS 27, try Start on-device pairing), connect LocalDevVPN, and choose Enable JIT in EmberSign for the signed target. The first request may download and mount a developer image. If built-in activation fails, the JIT page retains StikDebug and SideJITServer fallback methods.
7. In Tools > Installed apps, scan the paired device to inspect signing details or uninstall an app. In Tools > Auto refresh, enable background attempts and choose the remaining-days threshold.

The pairing record contains private device-trust credentials. EmberSign keeps its copy protected on device; exporting it is an explicit user action. Built-in StikJIT reads it locally. SideJITServer requests send only device/app identifiers to the address you configure. They do not upload your pairing file or signing keys.

## Build

Requires macOS, Xcode 26.3, XcodeGen, Rust, Git, Python 3, and network access for Swift packages and pinned StikJIT and signing engine dependencies.

```sh
swift test
bash scripts/bootstrap.sh
bash scripts/build.sh
```

The source engine is pinned in `upstream.lock.json`. Bootstrap checks out that exact revision, checks out its pinned submodules, and applies the source in `overrides` and the guarded modifications in `scripts/prepare.py`. The build script builds the pinned MPL-2.0 StikJIT framework with `jit-integration/EmberTargetLauncher.swift`, then generates a clean project from `project.yml`. The full assembled application can then be opened using `upstream/Feather.xcodeproj` and the Feather scheme. Internal project/model names remain unchanged to preserve engine compatibility; the installed application is EmberSign with its own bundle ID and URL scheme.

Every push to main runs core policy tests and builds an IPA on GitHub Actions. Successful builds publish the IPA, SHA-256, build metadata, and complete assembled source with licenses. Build logs are retained as Actions artifacts even when compilation fails. Runtime signing, installation, tweak loading, and JIT still need testing on a real device.

## Credits

Built on Feather by Samara M and contributors. Apple Account provisioning uses SideSign by the SideStore contributors. Built-in JIT uses the StikJIT framework from the StikDebug project (MPL-2.0). Original licenses and credits are preserved in the assembled source and NOTICE.md. StikDebug and SideJITServer remain independently maintained fallback tools.
