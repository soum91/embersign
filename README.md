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
- **Enable JIT** in a signed app's context menu and a dedicated JIT tools screen.
- StikDebug activation handoff for supported devices, plus a configurable SideJITServer client with device discovery and explicit server-reported status.
- A stable bundle identifier, `com.soum91.embersign`, and increasing build numbers. Updates must still be signed with the same identity and installed bundle identifier to retain app data.

## Current limits

Apple Account authentication and provisioning depend on Apple's private developer-service behavior and Anisette. Apple can change either flow without notice, public Anisette services can be unavailable, and repeated failed sign-ins can be rate-limited. EmberSign never stores the Apple Account password. Auth sessions and generated signing keys are stored in the iOS Keychain.

Automatic refresh is best-effort. iOS decides when background fetch runs, and reinstallation requires the matching pairing file and a reachable LocalDevVPN tunnel. Open EmberSign periodically and use **Refresh tracked apps now** if iOS has not granted background time.

A paired tunnel lets EmberSign query Apple's installation service for user-app metadata. Without a working pairing tunnel, EmberSign cannot enumerate all installed apps. An account can be matched when the app exposes a team identifier that belongs to one of the signed-in development teams.

Deleting a provisioning profile or App ID does not guarantee immediate quota recovery. Personal Team App IDs, devices, profiles, and the three-app per-device limit are enforced by Apple. Revoking a certificate can make every app signed with it stop launching.

Preparing entitlements is not the same as activating JIT. A distribution profile cannot be turned into a development profile by changing a switch. Actual JIT availability depends on iOS, hardware, debugger access, developer-image setup, and the target application's implementation. New iOS versions may require app-specific support.

EmberSign can export an imported pairing record. It does not generate fresh device trust entirely on an unpaired phone, read another application's private pairing file, or convert Lockdown records into remote-pairing records. Initial pairing normally uses a computer.

Tweak injection applies to the IPA being signed. Jailbreak-only services and system-wide tweaks are not supported. Use an unencrypted IPA compatible with the tweak and device architecture.

## Install and use

FlareStore/AltStore-compatible feed: `https://raw.githubusercontent.com/soum91/embersign/main/source.json`.
The release workflow updates this feed only after the IPA has been published successfully.
The feed version includes the build number (for example `0.2.0.11`), matching the installed app version.
If a client caches an older entry, refresh the source in that client.

1. Download `EmberSign.ipa` from Releases. The CI IPA is ad-hoc signed and must be re-signed using your existing signing tool before installing it.
2. In Tools > Apple Accounts, sign in and complete 2FA, or import an existing signing certificate/profile from Settings or Tools.
3. In Apps, import an IPA and choose Sign. Choose **Provision with Apple Account** to create a fresh identity for that bundle ID, or select an imported certificate. Add tweaks before signing. To prepare a compatible app for JIT, enable Prepare for JIT and use a development profile.
4. Install or export the signed IPA.
5. In Tools > Pairing file, import your trusted pairing record. Export a copy to Files when you need to import it into Reynard or another compatible tool.
6. For on-device JIT activation, import the appropriate pairing record into StikDebug, connect LocalDevVPN, complete its developer-image setup, and use Enable JIT in EmberSign. StikDebug displays the activation result. Alternatively configure your own SideJITServer address and choose your device.
7. In Tools > Installed apps, scan the paired device to inspect signing details or uninstall an app. In Tools > Auto refresh, enable background attempts and choose the remaining-days threshold.

The pairing record contains private device-trust credentials. EmberSign keeps its copy protected on device; exporting it is an explicit user action. JIT server requests send only device/app identifiers to the address you configure. They do not upload your pairing file or signing keys.

## Build

Requires macOS, Xcode 26.3, XcodeGen, Git, Python 3, and network access for Swift packages and engine dependencies.

```sh
swift test
bash scripts/bootstrap.sh
bash scripts/build.sh
```

The source engine is pinned in `upstream.lock.json`. Bootstrap checks out that exact revision, checks out its pinned submodules, and applies the source in `overrides` and the guarded modifications in `scripts/prepare.py`. The build script generates a clean project from `project.yml`, replacing duplicate upstream package links. The full assembled application can then be opened using `upstream/Feather.xcodeproj` and the Feather scheme. Internal project/model names remain unchanged to preserve engine compatibility; the installed application is EmberSign with its own bundle ID and URL scheme.

Every push to main runs core policy tests and builds an IPA on GitHub Actions. Successful builds publish the IPA, SHA-256, build metadata, and complete assembled source with licenses. Build logs are retained as Actions artifacts even when compilation fails. Runtime signing, installation, tweak loading, and JIT still need testing on a real device.

## Credits

Built on Feather by Samara M and contributors. Apple Account provisioning uses SideSign by the SideStore contributors. Original licenses and credits are preserved in the assembled source and NOTICE.md. StikDebug and SideJITServer are independently maintained companion tools.
