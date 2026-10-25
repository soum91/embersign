# EmberSign

An iOS 16+ app for signing and customizing IPAs on device, managing pairing files, and requesting JIT activation.

## Features

- On-device signing with an imported `.p12` certificate and `.mobileprovision` profile.
- IPA import, app library, signing options, installation, expiry display, and signed IPA export.
- Compatible `.dylib`, `.deb`, framework, and bundle injection before signing, inherited from Feather.
- A **Prepare for JIT** signing switch that validates the selected development profile before adding debugger permission.
- Pairing-file import, structural validation, atomic replacement, removal, and export through Files. Lockdown and remote-pairing formats remain distinct and are exported without altering their contents.
- **Enable JIT** in a signed app's context menu and a dedicated JIT tools screen.
- StikDebug activation handoff for supported devices, plus a configurable SideJITServer client with device discovery and explicit server-reported status.
- A stable bundle identifier, `com.soum91.embersign`, and increasing build numbers. Updates must still be signed with the same identity and installed bundle identifier to retain app data.

## Current limits

This first development version uses certificate/profile import. **Direct Apple Account authentication, automatic free-account provisioning/refresh, and a standalone embedded JIT engine are not implemented.** StikDebug is required for the on-device activation path. A computer running SideJITServer is an alternative.

Preparing entitlements is not the same as activating JIT. A distribution profile cannot be turned into a development profile by changing a switch. Actual JIT availability depends on iOS, hardware, debugger access, developer-image setup, and the target application's implementation. New iOS versions may require app-specific support.

EmberSign can export an imported pairing record. It does not generate fresh device trust entirely on an unpaired phone, read another application's private pairing file, or convert Lockdown records into remote-pairing records. Initial pairing normally uses a computer.

Tweak injection applies to the IPA being signed. Jailbreak-only services and system-wide tweaks are not supported. Use an unencrypted IPA compatible with the tweak and device architecture.

## Install and use

1. Download `EmberSign.ipa` from Releases. The CI IPA is ad-hoc signed and must be re-signed using your existing signing tool before installing it.
2. In Settings or Tools, import your signing certificate and profile.
3. In Apps, import an IPA and choose Sign. Add tweaks in the signing screen before signing. To prepare a compatible app for JIT, enable Prepare for JIT and select a development profile.
4. Install or export the signed IPA.
5. In Tools > Pairing file, import your trusted pairing record. Export a copy to Files when you need to import it into Reynard or another compatible tool.
6. For on-device JIT activation, import the appropriate pairing record into StikDebug, connect LocalDevVPN, complete its developer-image setup, and use Enable JIT in EmberSign. StikDebug displays the activation result. Alternatively configure your own SideJITServer address and choose your device.

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

Built on Feather by Samara M and contributors, with its original licenses and credits preserved. See NOTICE.md and LICENSE. StikDebug and SideJITServer are independently maintained companion tools.
