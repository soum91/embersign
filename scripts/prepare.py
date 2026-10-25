#!/usr/bin/env python3
"""Apply EmberSign changes to the exact source revision in upstream.lock.json."""
import json
from pathlib import Path
import plistlib
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path, before, after):
    text = path.read_text()
    if text.count(before) != 1:
        raise RuntimeError(f"Upstream source changed: expected one anchor in {path}")
    path.write_text(text.replace(before, after, 1))


def prepare(destination):
    destination = Path(destination).resolve()
    lock = json.loads((ROOT / "upstream.lock.json").read_text())
    app = destination / "Feather"
    if not (app / "FeatherApp.swift").exists():
        raise RuntimeError("Pass a checked-out Feather source directory.")
    for source in (ROOT / "overrides").rglob("*"):
        if source.is_file():
            target = destination / source.relative_to(ROOT / "overrides")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)

    options = app / "Backend/Observable/OptionsManager.swift"
    replace_once(options, "struct Options: Codable, Equatable {", "struct Options: Codable, Equatable {\n\t/// Prepare debugger entitlements using an authorized development profile.\n\tvar prepareForJIT: Bool = false")
    view = app / "Views/Signing/Shared/SigningOptionsView.swift"
    replace_once(view, '\t\tNBSection(.localized("General")) {', '''\t\tSection {
            Toggle(isOn: $options.prepareForJIT) {
                Label("Prepare for JIT", systemImage: "bolt.fill")
            }
        } footer: {
            Text("Requires a development profile with debugger permission. Activate JIT after installation from the JIT tools screen.")
        }

\t\tNBSection(.localized("General")) {''')
    signing = app / "Utilities/Handlers/SigningHandler.swift"
    replace_once(signing, '\t\tlet handler = ZsignHandler(appUrl: movedAppPath, options: _options, cert: appCertificate)', '''        if _options.prepareForJIT {
            guard let bundleID = Bundle(url: movedAppPath)?.bundleIdentifier else {
                throw SigningFileHandlerError.infoPlistNotFound
            }
            _options.appEntitlementsFile = try EmberJITEntitlements.prepare(
                certificate: appCertificate,
                existingFile: _options.appEntitlementsFile,
                bundleID: bundleID,
                output: _uniqueWorkDir.appendingPathComponent("EmberJITEntitlements.plist")
            )
        }

\t\tlet handler = ZsignHandler(appUrl: movedAppPath, options: _options, cert: appCertificate)''')
    # Never publish a failed signature as a successfully signed database entry.
    replace_once(signing, '\t\ttry await self.move()\n\t\ttry await self.addToDatabase()\n\t\t\n\t\tif let error = handler.hadError {\n\t\t\tthrow error\n\t\t}', '\t\tif let error = handler.hadError { throw error }\n\t\ttry await self.move()\n\t\ttry await self.addToDatabase()')

    tabs = app / "Views/TabView/TabEnum.swift"
    replace_once(tabs, '\tcase sources\n', '\tcase tools\n\tcase sources\n')
    replace_once(tabs, '\t\tcase .sources:     ', '\t\tcase .tools: return "Tools"\n\t\tcase .sources:     ')
    replace_once(tabs, '\t\tcase .sources: \t\treturn "globe.desk"', '\t\tcase .tools: return "flame.fill"\n\t\tcase .sources: \t\treturn "globe.desk"')
    replace_once(tabs, '\t\tcase .sources: SourcesView()', '\t\tcase .tools: EmberToolsView()\n\t\tcase .sources: SourcesView()')
    replace_once(tabs, '\t\t\t.sources,\n\t\t\t.library,\n\t\t\t.settings', '\t\t\t.library,\n\t\t\t.tools,\n\t\t\t.sources,\n\t\t\t.settings')
    replace_once(tabs, '.localized("Library")', '"Apps"')
    old_tabs = app / "Views/TabView/Bars/TabbarView.swift"
    replace_once(old_tabs, 'selectedTab: TabEnum = .sources', 'selectedTab: TabEnum = .library')

    settings = app / "Views/Settings/SettingsView.swift"
    replace_once(settings, 'private let _githubUrl = "https://github.com/claration/Feather"', 'private let _githubUrl = "https://github.com/soum91/embersign"')
    replace_once(settings, '\t\t\t\t#if !NIGHTLY && !DEBUG\n\t\t\t\t\tSettingsDonationCellView(site: _donationsUrl)\n\t\t\t\t#endif', '''                Section("EmberSign") {
                    NavigationLink { EmberPairingView() } label: {
                        Label("Pairing file", systemImage: "iphone.and.arrow.forward")
                    }
                    NavigationLink { EmberJITView() } label: {
                        Label("JIT", systemImage: "bolt.fill")
                    }
                }''')
    # Both the old tunnel settings screen and Tools use the same validated manager.
    (app / "Views/Settings/Installation/Tunnel & Pairing/TunnelView.swift").write_text('import SwiftUI\n\nstruct TunnelView: View {\n    var body: some View { EmberPairingView() }\n}\n')
    cell = app / "Views/Library/LibraryCellView.swift"
    replace_once(cell, '\t\t\t\tButton(.localized("Open"), systemImage: "app.badge.checkmark") {', '''                Button("Enable JIT", systemImage: "bolt.fill") {
                    EmberJITService.shared.present(bundleID: id)
                }
\t\t\t\tButton(.localized("Open"), systemImage: "app.badge.checkmark") {''')
    main = app / "FeatherApp.swift"
    replace_once(main, '\t@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate', '\t@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate\n    @StateObject private var emberJIT = EmberJITService.shared')
    replace_once(main, '\t\t\t.animation(.smooth, value: downloadManager.manualDownloads.description)', '''            .sheet(isPresented: $emberJIT.showAppSheet) {
                NavigationStack {
                    EmberJITView()
                        .toolbar { ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { emberJIT.showAppSheet = false }
                        } }
                }
            }
\t\t\t.animation(.smooth, value: downloadManager.manualDownloads.description)''')
    replace_once(main, 'if url.scheme == "feather" {', 'if url.scheme == "embersign" {')
    replace_once(main, '\t\t} else {\n\t\t\tif url.pathExtension == "ipa"', '''\t\t} else {
            if ["plist", "mobiledevicepairing", "mobiledevicepair"].contains(url.pathExtension.lowercased()) {
                UIAlertController.showAlertWithCancel(
                    title: "Import pairing file",
                    message: "Replace EmberSign's pairing file with this record?",
                    actions: [UIAlertAction(title: "Import", style: .default) { _ in
                        do { try EmberPairingStore.importFile(url) }
                        catch { UIAlertController.showAlertWithOk(title: "Import failed", message: error.localizedDescription) }
                    }]
                )
                return
            }
\t\t\tif url.pathExtension == "ipa"''')
    # Keep storage/model names stable, but make this app own only its new URL scheme.
    for swift in app.rglob("*.swift"):
        content = swift.read_text()
        content = content.replace("scheme=feather", "scheme=embersign")
        content = content.replace('?? "#848ef9"', '?? "#F27A35"')
        swift.write_text(content)

    replace_once(main, "    @StateObject private var emberJIT = EmberJITService.shared", "    @StateObject private var emberJIT = EmberJITService.shared\n    @StateObject private var emberQuickRouter = EmberQuickRouter.shared")
    replace_once(main, "            .sheet(isPresented: $emberJIT.showAppSheet) {", """            .onAppear { EmberWidgetSync.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)) { _ in EmberWidgetSync.refresh() }
            .sheet(item: $emberQuickRouter.destination) { destination in
                EmberQuickSheet(destination: destination)
                    .environment(\\.managedObjectContext, storage.context)
            }
            .sheet(isPresented: $emberJIT.showAppSheet) {""")

    project = destination / "Feather.xcodeproj/project.pbxproj"
    content = project.read_text().replace('INFOPLIST_KEY_CFBundleDisplayName = Feather;', 'INFOPLIST_KEY_CFBundleDisplayName = EmberSign;')
    # Alternate inherited team values must not affect this application's signing identity.
    content = content.replace('DEVELOPMENT_TEAM = 566RT33SA2;', 'DEVELOPMENT_TEAM = "";')
    project.write_text(content)
    (destination / "Feather.xcconfig").write_text(f'''FEATHER_PROJECT_VERSION={lock["version"]}
FEATHER_PRODUCT_BUNDLE_IDENTIFIER={lock["bundle_identifier"]}
FEATHER_DISAMBIGUATOR=
AD_HOC_CODE_SIGNING_ALLOWED = YES
DEPLOYMENT_LOCATION = YES
DSTROOT = $(SRCROOT)/_build/
''')
    info = app / "Resources/Info.plist"
    plist = plistlib.loads(info.read_bytes())
    for entry in plist["CFBundleURLTypes"]:
        entry["CFBundleURLName"] = lock["bundle_identifier"]
        entry["CFBundleURLSchemes"] = ["embersign"]
    plist["LSApplicationQueriesSchemes"] = ["localdevvpn", "stikdebug"]
    plist["NSLocalNetworkUsageDescription"] = "Connect to your trusted pairing tunnel or JIT server to install and debug your apps."
    ats = plist.setdefault("NSAppTransportSecurity", {})
    ats["NSAllowsLocalNetworking"] = True
    # Keep local networking support without a global transport-security exception.
    ats.pop("NSAllowsArbitraryLoads", None)
    plist["CFBundleDocumentTypes"].append({
        "CFBundleTypeName": "Device pairing file", "CFBundleTypeRole": "Viewer",
        "LSHandlerRank": "Alternate", "LSItemContentTypes": ["com.soum91.embersign.pairing"]
    })
    plist["UTExportedTypeDeclarations"].append({
        "UTTypeIdentifier": "com.soum91.embersign.pairing", "UTTypeConformsTo": ["public.data"],
        "UTTypeDescription": "Device pairing file",
        "UTTypeTagSpecification": {"public.filename-extension": ["mobiledevicepairing", "mobiledevicepair"]}
    })
    info.write_bytes(plistlib.dumps(plist))
    shutil.copy2(ROOT / "NOTICE.md", app / "Resources/EmberSign-Notice.md")
    print(f"Prepared EmberSign {lock['version']} at {destination}")


if __name__ == "__main__":
    prepare(sys.argv[1])
