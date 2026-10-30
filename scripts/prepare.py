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


def replace_first(path, before, after):
    """Patch the first signing entry point, not the later certificate inspector."""
    text = path.read_text()
    if before not in text:
        raise RuntimeError(f"Upstream source changed: missing anchor in {path}")
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

    # Zsign's C++ engine can already match each nested bundle with a different
    # ZSignAsset, but its Swift bridge exposes just one profile. Preserve the
    # public Swift API and accept newline-separated profile paths for the Watch
    # signing flow. Normal single-profile signing is unchanged.
    zsign_bridge = destination / "Zsign/swift/zsign.mm"
    replace_first(zsign_bridge,
        'strProvFile = [prov cStringUsingEncoding:NSUTF8StringEncoding];',
        '''strProvFile = [prov cStringUsingEncoding:NSUTF8StringEncoding];
    std::vector<std::string> emberProvisionPaths;
    size_t emberStart = 0;
    while (true) {
        size_t emberEnd = strProvFile.find('\\n', emberStart);
        std::string emberPath = strProvFile.substr(emberStart, emberEnd == std::string::npos ? std::string::npos : emberEnd - emberStart);
        if (!emberPath.empty()) emberProvisionPaths.push_back(emberPath);
        if (emberEnd == std::string::npos) break;
        emberStart = emberEnd + 1;
    }
    if (emberProvisionPaths.size() > 1) strProvFile = emberProvisionPaths.front();''')
    replace_once(zsign_bridge,
        'bool bRet = bundle.SignFolder(&zsa, strFolder, strBundleId, strBundleVersion, strDisplayName, arrDylibFiles, arrDisDylibFiles, bForce, bWeakInject, bEnableCache, excludeprovion);',
        '''bool bRet = false;
    if (emberProvisionPaths.size() > 1) {
        std::list<ZSignAsset> emberAssets;
        for (const std::string& emberPath : emberProvisionPaths) {
            emberAssets.emplace_back();
            if (!emberAssets.back().Init(strCertFile, strPKeyFile, emberPath, strEntitleFile, strPassword, bAdhoc, bSHA256Only, false)) {
                ZLog::ErrorV(\">>> Could not load Watch profile: %s\\n\", emberPath.c_str());
                return -1;
            }
        }
        bRet = bundle.SignFolder(&emberAssets, strFolder, strBundleId, strBundleVersion, strDisplayName, arrDylibFiles, arrDisDylibFiles, bForce, bWeakInject, bEnableCache, excludeprovion);
    } else {
        bRet = bundle.SignFolder(&zsa, strFolder, strBundleId, strBundleVersion, strDisplayName, arrDylibFiles, arrDisDylibFiles, bForce, bWeakInject, bEnableCache, excludeprovion);
    }''')

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

    # Feather already parses AltStore/FlareStore JSON feeds and downloads IPAs.
    # Make GitHub repository and blob URLs first-class entry points into that flow.
    source_add = app / "Views/Sources/SourcesAddView.swift"
    replace_once(source_add, '"https://raw.githubusercontent.com/claration/Feather/refs/heads/main/app-repo.json",',
                 '"https://raw.githubusercontent.com/soum91/embersign/main/source.json",\n\t\t"https://raw.githubusercontent.com/claration/Feather/refs/heads/main/app-repo.json",')
    replace_once(source_add, '@State private var _sourceURL = ""',
                 '@State private var _sourceURL = ""\n\t@State private var _githubError: String?')
    replace_once(source_add, 'TextField(.localized("Enter Source URL"), text: $_sourceURL)',
                 'TextField("GitHub repository or source.json URL", text: $_sourceURL)')
    replace_once(source_add, 'Text(.localized("The only supported repositories are AltStore repositories."))',
                 '''Text("Add a public GitHub repository, a GitHub JSON file, or an AltStore/FlareStore-compatible source URL. Apps download into the Apps library for signing and installation.")
                    if let _githubError { Text(_githubError).foregroundStyle(.red) }''')
    replace_once(source_add, '''FR.handleSource(_sourceURL) {
\t\t\t\t\t\t\tdismiss()
\t\t\t\t\t\t}''', '''_isImporting = true
                    _githubError = nil
                    Task {
                        do {
                            let resolved = try await EmberGitHubSource.resolve(_sourceURL)
                            await MainActor.run {
                                FR.handleSource(resolved) { dismiss() }
                                _isImporting = false
                            }
                        } catch {
                            await MainActor.run {
                                _githubError = error.localizedDescription
                                _isImporting = false
                            }
                        }
                    }''')
    source_add.write_text(source_add.read_text() + '''

// Resolve GitHub links to an actual public feed. Never treat GitHub's HTML page as JSON.
private enum EmberGitHubSource {
    enum Failure: LocalizedError {
        case invalidGitHubURL, missingFeed
        var errorDescription: String? {
            switch self {
            case .invalidGitHubURL: return "Use a GitHub repository link or a JSON file link."
            case .missingFeed: return "No public AltStore-compatible JSON feed found (source.json, apps.json, app-repo.json, or AltStore.json)."
            }
        }
    }

    static func resolve(_ input: String) async throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), let host = url.host?.lowercased() else {
            throw Failure.invalidGitHubURL
        }
        guard host == "github.com" || host == "www.github.com" else {
            return value // The existing source importer handles regular JSON URLs.
        }
        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count >= 2 else { throw Failure.invalidGitHubURL }
        let owner = path[0], repo = path[1]
        guard owner.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
              repo.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            throw Failure.invalidGitHubURL
        }
        if path.count >= 5 && (path[2] == "blob" || path[2] == "raw") {
            let branch = path[3]
            let file = path.dropFirst(4).joined(separator: "/")
            return "https://raw.githubusercontent.com/\\(owner)/\\(repo)/\\(branch)/\\(file)"
        }
        guard path.count == 2 else { throw Failure.invalidGitHubURL }
        let metadataURL = URL(string: "https://api.github.com/repos/\\(owner)/\\(repo)")!
        var request = URLRequest(url: metadataURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let branch = metadata["default_branch"] as? String else {
            throw Failure.missingFeed // Private repositories need authenticated access.
        }
        for name in ["source.json", "apps.json", "app-repo.json", "AltStore.json"] {
            let candidate = URL(string: "https://raw.githubusercontent.com/\\(owner)/\\(repo)/\\(branch)/\\(name)")!
            var probe = URLRequest(url: candidate)
            probe.timeoutInterval = 15
            if let (body, reply) = try? await URLSession.shared.data(for: probe),
               (reply as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               json["apps"] is [[String: Any]] {
                return candidate.absoluteString
            }
        }
        throw Failure.missingFeed
    }
}
''')

    settings = app / "Views/Settings/SettingsView.swift"
    replace_once(settings, 'private let _githubUrl = "https://github.com/claration/Feather"', 'private let _githubUrl = "https://github.com/soum91/embersign"')
    replace_once(settings, '\t\t\t\t#if !NIGHTLY && !DEBUG\n\t\t\t\t\tSettingsDonationCellView(site: _donationsUrl)\n\t\t\t\t#endif', '''                Section("EmberSign") {
                    NavigationLink { EmberAccountsView() } label: {
                        Label("Apple Accounts", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    NavigationLink { EmberDeviceAppsView() } label: {
                        Label("Installed apps", systemImage: "square.grid.2x2")
                    }
                    NavigationLink { EmberAutoRefreshView() } label: {
                        Label("Auto refresh", systemImage: "arrow.triangle.2.circlepath")
                    }
                    NavigationLink { EmberPairingView() } label: {
                        Label("Pairing file", systemImage: "iphone.and.arrow.forward")
                    }
                    NavigationLink { EmberJITView() } label: {
                        Label("JIT", systemImage: "bolt.fill")
                    }
                    NavigationLink { EmberErrorCenterView() } label: {
                        Label("Error diagnostics", systemImage: "stethoscope")
                    }
                }''')
    # Both the old tunnel settings screen and Tools use the same validated manager.
    (app / "Views/Settings/Installation/Tunnel & Pairing/TunnelView.swift").write_text('import SwiftUI\n\nstruct TunnelView: View {\n    var body: some View { EmberPairingView() }\n}\n')
    cell = app / "Views/Library/LibraryCellView.swift"
    replace_once(cell, '\t\t\t\tButton(.localized("Open"), systemImage: "app.badge.checkmark") {', '''                Button("Enable JIT", systemImage: "bolt.fill") {
                    EmberJITService.shared.present(bundleID: id)
                }
\t\t\t\tButton(.localized("Open"), systemImage: "app.badge.checkmark") {''')
    signing_view = app / "Views/Signing/SigningView.swift"
    replace_once(signing_view, '\t@State private var _isSigning = false', '\t@State private var _isSigning = false\n    @State private var _isAppleProvisioning = false')
    replace_once(signing_view, '\t\tNBSection(.localized("Signing")) {\n\t\t\tif let cert = _selectedCert() {', '''\t\tNBSection(.localized("Signing")) {
            if !EmberAccountManager.shared.accounts.isEmpty {
                Button {
                    _provisionWithAppleAccount()
                } label: {
                    HStack {
                        Label("Provision with Apple Account", systemImage: "person.crop.circle.badge.checkmark")
                        Spacer()
                        if _isAppleProvisioning { ProgressView() }
                    }
                }
                .disabled(_isAppleProvisioning)
            } else {
                NavigationLink { EmberAccountsView() } label: {
                    Label("Add Apple Account", systemImage: "person.crop.circle.badge.plus")
                }
            }
\t\t\tif let cert = _selectedCert() {''')
    replace_once(signing_view, '// MARK: - Extension: View (import)\nextension SigningView {\n\tprivate func _start() {', '''// MARK: - Extension: View (import)
extension SigningView {
    private func _provisionWithAppleAccount() {
        guard let identifier = _temporaryOptions.appIdentifier ?? app.identifier else { return }
        _isAppleProvisioning = true
        Task {
            do {
                _ = try await EmberAccountManager.shared.provisionSigningIdentity(bundleID: identifier)
                _temporaryCertificate = 0
            } catch {
                EmberErrorCenter.shared.record(error, operation: "Provision signing identity")
                UIAlertController.showAlertWithOk(title: "Provisioning failed", message: error.localizedDescription)
            }
            _isAppleProvisioning = false
        }
    }

\tprivate func _start() {''')
    main = app / "FeatherApp.swift"
    replace_once(main, '\t@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate', '\t@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate\n    @StateObject private var emberJIT = EmberJITService.shared')
    replace_once(main, '\t\t_addDefaultCertificates()\n\t\treturn true', '''\t\t_addDefaultCertificates()
        EmberAutoRefreshManager.shared.configure()
\t\treturn true''')
    replace_once(main, '\n\tprivate func _createPipeline() {', '''
    func application(
        _ application: UIApplication,
        performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard EmberAutoRefreshManager.shared.enabled || EmberWatchRefreshManager.shared.enabled else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            let succeeded = await EmberAutoRefreshManager.shared.refreshAll()
            completionHandler(succeeded ? .newData : .failed)
        }
    }

\tprivate func _createPipeline() {''')
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

    replace_once(main, "import SwiftUI", "import SwiftUI\nimport CoreData")
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
    plist["NSBonjourServices"] = ["_remotepairing-pairable-host._tcp"]
    plist["BGTaskSchedulerPermittedIdentifiers"] = ["$(PRODUCT_BUNDLE_IDENTIFIER).pairing.*"]
    plist["UIBackgroundModes"] = ["fetch", "processing"]
    ats = plist.setdefault("NSAppTransportSecurity", {})
    ats["NSAllowsLocalNetworking"] = True
    # Local services retain their scoped exception; do not disable global ATS.
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
