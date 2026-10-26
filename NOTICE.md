# Attribution and source

EmberSign is an independent derivative of Feather by Samara M (khcrysalis/claration) and Feather's contributors. EmberSign is not an official Feather, SideStore, StikDebug, or Apple product.

The signing engine and its original application code are fetched from:

- https://github.com/claration/feather
- Exact revision: `7078b053c0af262809a48e4d3898d42b0d35fedf`
- License: GNU General Public License version 3. The full license is in LICENSE.

Original source headers, developer credits, dependency attributions, and dependency licenses are retained in the assembled source distribution. EmberSign has its own About screen with visible Feather and SideSign attribution. EmberSign modifications and additions are also licensed under GPL-3.0. `scripts/prepare.py` identifies the changes to the original application; the `overrides` directory contains EmberSign's additional and replacement source. Build releases include the complete assembled source with the upstream submodules at their pinned revisions.

Feather dependencies include Zsign, IDeviceKit/idevice, NimbleKit, AltSourceKit, Zip, SWCompression, Nuke, and Vapor. Their respective licenses continue to apply.

Apple Account authentication and provisioning use SideSign from the SideStore project at revision `752d1ef602aa792a432ffa1e71646dc1ecf7363c`, licensed under GPL-3.0. SideSign includes CodeSignKit, GSACryptoKit, AnisetteKit, swift-crypto, and libdeflate dependencies whose respective licenses continue to apply.

StikDebug and SideJITServer are separate programs; EmberSign retains their documented fallback interfaces. The built-in JIT engine is StikJIT, copyright its authors, licensed under Mozilla Public License 2.0 (MPL-2.0), revision `32287268fa5824f9edce4cb359f5833ce0cf7b00`. EmberSign dynamically links its framework and builds a small additional process-launcher file into that framework. The original and modified StikJIT source, IDevice FFI and license are distributed with each build in `EmberSign-Source.tar.gz`. StikJIT remains an independent project; this is not an official StikJIT release.

On-device remote pairing for iOS 27 uses a new MIT-licensed Rust wrapper in `pairing-native/` and the MIT-licensed `jkcoxson/idevice` crate (version 0.1.68). EmberSign bundles the resulting static library, and its corresponding Rust and C source is included with source releases. Other crates retain their own permissive licenses. The native pairing capability is independent of StikDebug, which remains a separate application.
