# Attribution and source

EmberSign is an independent derivative of Feather by Samara M (khcrysalis/claration) and Feather's contributors. EmberSign is not an official Feather, SideStore, StikDebug, or Apple product.

The signing engine and its original application code are fetched from:

- https://github.com/claration/feather
- Exact revision: `7078b053c0af262809a48e4d3898d42b0d35fedf`
- License: GNU General Public License version 3. The full license is in LICENSE.

Original source headers, About screen, dependency attributions, and dependency licenses are retained in the assembled source distribution. EmberSign modifications and additions are also licensed under GPL-3.0. `scripts/prepare.py` identifies the changes to the original application; the `overrides` directory contains EmberSign's additional source. Build releases include the complete assembled source with the upstream submodules at their pinned revisions.

Feather dependencies include Zsign, IDeviceKit/idevice, NimbleKit, AltSourceKit, Zip, SWCompression, Nuke, and Vapor. Their respective licenses continue to apply.

StikDebug and SideJITServer are separate programs. EmberSign invokes their documented interfaces; they are not bundled or represented as EmberSign's own JIT engine.
