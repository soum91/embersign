import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ZIPFoundation
import EmberPairingNative
import Zsign
import IDeviceSwift

@MainActor
private final class EmberWatchProgress: ObservableObject {
    static let shared = EmberWatchProgress()
    @Published var status = "Connect LocalDevVPN and use your saved remote pairing file."
}

struct EmberWatchTrackedApp: Codable {
    var bundleID: String
    var version: String
    var build: String
    var accountID: String
    var expiresAt: Date
    var expirationEstimated: Bool
    var lastInstalled: Date
    var sourceURL: String
    /// Feed app and build this install came from. The IPA's own bundle ID
    /// (e.g. dev.watchlink.companion) and CFBundleVersion can differ from the
    /// repo's source.json entry, so update checks match on these instead.
    var feedBundleID: String? = nil
    var feedBuild: String? = nil
    var name: String? = nil
}

struct EmberWatchRelease: Decodable {
    let version: String
    let buildVersion: String
    let downloadURL: String
    let size: Int?
}

private struct EmberWatchFeed: Decodable {
    struct App: Decodable {
        let bundleIdentifier: String
        let versions: [EmberWatchRelease]?
    }
    let apps: [App]
}

enum EmberWatchRefreshOutcome: Equatable {
    case skipped, success, failed
}

/// Watch companions require a separately provisioned Watch and widget, so they
/// must never go through the iPhone-only auto-refresh signing route.
/// Every Watch app (WristPane, WatchLink, ...) is tracked separately with its
/// own repo feed and cached unsigned IPA.
@MainActor
final class EmberWatchRefreshManager: ObservableObject {
    static let shared = EmberWatchRefreshManager()
    static let defaultSource = "https://raw.githubusercontent.com/soum91/wristpane/main/source.json"

    @Published private(set) var trackedApps: [EmberWatchTrackedApp] = []
    @Published private(set) var latestRelease: EmberWatchRelease?
    @Published private(set) var latestFeedBundleID: String?
    @Published private(set) var isWorking = false
    @Published private(set) var isChecking = false
    @Published var status = "Install a Watch IPA once with EmberSign to save it for future refreshes."

    /// Most recently installed Watch app.
    var tracked: EmberWatchTrackedApp? { trackedApps.max(by: { $0.lastInstalled < $1.lastInstalled }) }

    private let legacyTrackingKey = "EmberSign.watch.trackedApp"
    private let trackingKey = "EmberSign.watch.trackedApps"
    private let refreshEnabledKey = "EmberSign.watch.autoRefresh"
    private let refreshDaysKey = "EmberSign.watch.refreshDays"

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: trackingKey),
           let apps = try? JSONDecoder().decode([EmberWatchTrackedApp].self, from: data) {
            trackedApps = apps
        } else if let data = defaults.data(forKey: legacyTrackingKey),
                  let app = try? JSONDecoder().decode(EmberWatchTrackedApp.self, from: data) {
            // Migrate the single-app tracker and its cached IPA.
            let legacy = Self.folder.appendingPathComponent("tracked-unsigned.ipa")
            let target = Self.cachedIPA(for: app.bundleID)
            if FileManager.default.fileExists(atPath: legacy.path), !FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.moveItem(at: legacy, to: target)
            }
            trackedApps = [app]
            persist()
        }
    }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: refreshEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: refreshEnabledKey)
            EmberAutoRefreshManager.shared.configure()
            objectWillChange.send()
        }
    }

    var thresholdDays: Int {
        get {
            let saved = UserDefaults.standard.integer(forKey: refreshDaysKey)
            return (1...3).contains(saved) ? saved : 2
        }
        set { UserDefaults.standard.set(newValue, forKey: refreshDaysKey); objectWillChange.send() }
    }

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EmberSign-WatchRefresh", isDirectory: true)
    }

    private static func cachedIPA(for bundleID: String) -> URL {
        let safe = bundleID.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return folder.appendingPathComponent("tracked-\(String(safe)).ipa")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(trackedApps) {
            UserDefaults.standard.set(data, forKey: trackingKey)
        }
    }

    static func repoSource(bundleID: String, requested: String, existing: String?) -> String {
        EmberWatchRepositoryPolicy.source(bundleID: bundleID, requested: requested,
                                          existing: existing, defaultSource: defaultSource)
    }

    private func isDue(_ app: EmberWatchTrackedApp) -> Bool {
        app.expiresAt.timeIntervalSinceNow <= Double(thresholdDays) * 86_400
    }

    /// Updates every tracked Watch app from its repo when a newer build exists,
    /// otherwise re-signs the cached build when its profile is about to expire.
    func refreshIfNeeded(force: Bool = false) async -> EmberWatchRefreshOutcome {
        guard enabled || force, !trackedApps.isEmpty else { return .skipped }
        guard !isWorking else { return .skipped }
        var outcome = EmberWatchRefreshOutcome.skipped
        for app in trackedApps {
            switch await refresh(app, force: force) {
            case .failed: outcome = .failed
            case .success: if outcome != .failed { outcome = .success }
            case .skipped: break
            }
        }
        return outcome
    }

    func refresh(_ app: EmberWatchTrackedApp, force: Bool) async -> EmberWatchRefreshOutcome {
        var app = app
        app.sourceURL = Self.repoSource(bundleID: app.bundleID, requested: app.sourceURL, existing: nil)
        guard EmberAccountManager.shared.selectedAccountID == app.accountID else {
            status = "Select the original Apple Account (\(app.accountID)) before renewing \(app.bundleID)."
            return .failed
        }
        if !app.sourceURL.isEmpty, (try? Self.validatedSource(app.sourceURL)) != nil {
            await checkForUpdates(sourceURL: app.sourceURL, for: app)
            if latestRelease != nil {
                do {
                    try await installLatestFromGitHub(sourceURL: app.sourceURL)
                    return .success
                } catch {
                    status = "\(app.bundleID) update from repo failed: \(error.localizedDescription)"
                    EmberErrorCenter.shared.record(error, operation: "Watch repo update")
                    return .failed
                }
            }
        }
        guard force || isDue(app) else { return .skipped }
        let cached = Self.cachedIPA(for: app.bundleID)
        guard FileManager.default.fileExists(atPath: cached.path) else {
            status = "The saved unsigned IPA for \(app.bundleID) is missing. Reinstall it from its repo once."
            return .failed
        }
        do {
            try await installAndTrack(file: cached, sourceURL: app.sourceURL)
            return .success
        } catch {
            status = "Watch refresh of \(app.bundleID) failed: \(error.localizedDescription)"
            EmberErrorCenter.shared.record(error, operation: "Watch auto refresh")
            return .failed
        }
    }

    /// Checks a repo feed. With `app`, compares against that tracked app;
    /// otherwise matches any tracked app from this feed, the feed's only app,
    /// or WristPane.
    func checkForUpdates(sourceURL: String, for app: EmberWatchTrackedApp? = nil) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        latestRelease = nil
        latestFeedBundleID = nil
        do {
            let source = try Self.validatedSource(sourceURL)
            let (data, _) = try await URLSession.shared.data(from: source)
            guard data.count <= 1_048_576 else { throw EmberError.message("The GitHub source exceeds 1 MB.") }
            let feed = try JSONDecoder().decode(EmberWatchFeed.self, from: data)
            let candidates = app.map { [$0] } ?? trackedApps.filter { $0.sourceURL == sourceURL }
            var matchedApp: EmberWatchFeed.App?
            var compareWith: EmberWatchTrackedApp?
            for candidate in candidates {
                let ids = [candidate.feedBundleID, candidate.bundleID].compactMap { $0 }
                if let hit = feed.apps.first(where: { ids.contains($0.bundleIdentifier) }) {
                    matchedApp = hit; compareWith = candidate; break
                }
            }
            if matchedApp == nil, app == nil {
                matchedApp = feed.apps.count == 1 ? feed.apps[0]
                    : feed.apps.first(where: { $0.bundleIdentifier == "com.soum91.wristpane" })
                if let hit = matchedApp {
                    compareWith = trackedApps.first(where: { $0.feedBundleID == hit.bundleIdentifier || $0.bundleID == hit.bundleIdentifier })
                }
            }
            guard let feedApp = matchedApp,
                  let release = feedApp.versions?.max(by: { Self.isNewer($1, than: $0) }) else {
                throw EmberError.message("No Watch IPA release found for \(app?.feedBundleID ?? app?.bundleID ?? "this app") in this source.")
            }
            guard try Self.validatedDownload(release.downloadURL) != nil else {
                throw EmberError.message("The source has an invalid release download URL.")
            }
            if let compareWith, !Self.isNewer(release, than: compareWith) {
                status = "\(feedApp.bundleIdentifier) is up to date (build \(compareWith.feedBuild ?? compareWith.build))."
            } else {
                latestRelease = release
                latestFeedBundleID = feedApp.bundleIdentifier
                status = "\(feedApp.bundleIdentifier) \(release.version) (build \(release.buildVersion)) is available. Ready to download and sign."
            }
        } catch {
            status = "GitHub update check failed: \(error.localizedDescription)"
            EmberErrorCenter.shared.record(error, operation: "Watch GitHub update check")
        }
    }

    func installLatestFromGitHub(sourceURL: String) async throws {
        guard !isWorking else { throw EmberError.message("Another Watch operation is already running.") }
        if latestRelease == nil { await checkForUpdates(sourceURL: sourceURL) }
        guard let release = latestRelease else {
            throw EmberError.message("No newer release was found. Use the refresh button if you need to renew the current build.")
        }
        guard let url = try Self.validatedDownload(release.downloadURL) else {
            throw EmberError.message("Invalid GitHub release address.")
        }
        let feedBundleID = latestFeedBundleID
        status = "Downloading unsigned Watch IPA from GitHub…"
        let (download, _) = try await URLSession.shared.download(from: url)
        let bytes = (try FileManager.default.attributesOfItem(atPath: download.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0, bytes <= 128 * 1024 * 1024 else {
            throw EmberError.message("The release IPA is empty or larger than 128 MB.")
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("EmberWatchGitHub-\(UUID()).ipa")
        try FileManager.default.copyItem(at: download, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        try await installAndTrack(file: copy, sourceURL: sourceURL,
                                  feedBundleID: feedBundleID, feedBuild: release.buildVersion)
        latestRelease = nil
        latestFeedBundleID = nil
    }

    /// Called for a Watch app downloaded from a repo in Sources: sign it with
    /// separate profiles, install to iPhone + Watch, and track that repo.
    func installFromSource(file: URL, provenance: SourceAppProvenance) async throws {
        let sourceURL = provenance.sourceRepositoryURL.absoluteString
        var feedBuild: String?
        if let source = try? Self.validatedSource(sourceURL),
           let data = (try? await URLSession.shared.data(from: source))?.0, data.count <= 1_048_576,
           let feed = try? JSONDecoder().decode(EmberWatchFeed.self, from: data),
           let feedApp = feed.apps.first(where: { $0.bundleIdentifier == provenance.sourceAppIdentifier }) {
            let versions = feedApp.versions ?? []
            feedBuild = versions.first(where: { URL(string: $0.downloadURL) == provenance.sourceAppDownloadURL })?.buildVersion
                ?? versions.first(where: { $0.version == provenance.sourceAppVersion })?.buildVersion
        }
        try await installAndTrack(file: file,
                                  sourceURL: (try? Self.validatedSource(sourceURL)) != nil ? sourceURL : "",
                                  feedBundleID: provenance.sourceAppIdentifier, feedBuild: feedBuild)
    }

    func installAndTrack(file: URL, sourceURL: String,
                         feedBundleID: String? = nil, feedBuild: String? = nil) async throws {
        guard !isWorking else { throw EmberError.message("Another Watch operation is already running.") }
        guard let account = EmberAccountManager.shared.selectedAccount else {
            throw EmberError.message("Sign into an Apple Account in EmberSign first.")
        }
        isWorking = true
        defer { isWorking = false }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EmberWatchSigning-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.ipa")
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: file, to: input)

        func progress(_ message: String) {
            status = message
            EmberWatchProgress.shared.status = message
        }
        progress("Finding paired Watch through LocalDevVPN…")
        let endpoint = UserDefaults.standard.string(forKey: "EmberSign.jit.endpoint.deviceIP") ?? "10.7.0.1"
        let port = UserDefaults.standard.integer(forKey: "EmberSign.jit.endpoint.port")
        let pairingPort = port == 0 ? 49152 : port
        guard (1...65535).contains(pairingPort) else { throw EmberError.message("Invalid remote pairing port.") }
        let (phoneID, watchID) = try await Task.detached(priority: .userInitiated) {
            try emberDiscoverSingleWatch(deviceIP: endpoint, port: UInt16(pairingPort))
        }.value

        progress("Extracting and validating iPhone and Watch IPA…")
        let (host, plan) = try await Task.detached(priority: .userInitiated) {
            try emberExtractWatchIPA(at: input, into: root)
        }.value
        guard plan.hasWatchCompanion else { throw EmberError.message("The IPA has no embedded Watch app.") }
        let existing = trackedApps.first(where: { $0.bundleID == plan.targets[0].bundleID })
        if let existing, existing.accountID != account.id {
            throw EmberError.message("\(existing.bundleID) was last signed using \(existing.accountID). Select that account to preserve its signing identity.")
        }
        progress("Obtaining separate iPhone, Watch and widget provisioning profiles…")
        let identity = try await EmberAccountManager.shared.provisionWatchCompanion(plan: plan,
                                                                                    iphoneUDID: phoneID, watchUDID: watchID)
        let exactExpiration = Self.profileExpiration(identity.profiles)
        let estimatedExpiration = Date().addingTimeInterval(7 * 86_400)
        progress("Signing all iPhone and Watch targets…")
        let package = try await Task.detached(priority: .userInitiated) {
            try emberSignWatchIPA(host: host, plan: plan, identity: identity, root: root)
        }.value
        progress("Installing the iPhone host…")
        let installer = InstallationProxy(viewModel: InstallerStatusViewModel(isIdevice: true))
        try await installer.install(at: package)
        progress("Installing the paired Apple Watch companion…")
        let hostID = emberSavedWatchIdentifier("EmberSign.watch.hostID")
        let systemBUID = emberSavedWatchIdentifier("EmberSign.watch.systemBUID")
        _ = try await Task.detached(priority: .userInitiated) {
            try emberStreamWatchBundle(host: host, plan: plan, pairingURL: EmberPairingStore.url,
                                       deviceIP: endpoint, devicePort: UInt16(pairingPort),
                                       hostID: hostID, systemBUID: systemBUID)
        }.value

        let plist = try PropertyListSerialization.propertyList(from:
            Data(contentsOf: host.appendingPathComponent("Info.plist")), format: nil) as? [String: Any]
        let version = plist?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = plist?["CFBundleVersion"] as? String ?? "unknown"
        let bundleID = plan.targets[0].bundleID
        let isCachedRefresh = file.standardizedFileURL == Self.cachedIPA(for: bundleID).standardizedFileURL
        let record = EmberWatchTrackedApp(bundleID: bundleID, version: version,
                                          build: build, accountID: account.id,
                                          expiresAt: exactExpiration ?? estimatedExpiration,
                                          expirationEstimated: exactExpiration == nil,
                                          lastInstalled: Date(),
                                          sourceURL: Self.repoSource(bundleID: bundleID, requested: sourceURL,
                                                                     existing: existing?.sourceURL),
                                          feedBundleID: feedBundleID ?? existing?.feedBundleID,
                                          feedBuild: feedBuild ?? (isCachedRefresh ? existing?.feedBuild : nil),
                                          name: plist?["CFBundleDisplayName"] as? String ?? plist?["CFBundleName"] as? String)
        do {
            try remember(input, record: record)
            progress("\(bundleID) installed and saved for refresh (build \(record.feedBuild ?? build)).")
        } catch {
            progress("Watch installed, but saving its refresh copy failed: \(error.localizedDescription)")
            EmberErrorCenter.shared.record(error, operation: "Save Watch refresh IPA")
        }
    }

    func stopTracking(_ app: EmberWatchTrackedApp) {
        trackedApps.removeAll { $0.bundleID == app.bundleID }
        try? FileManager.default.removeItem(at: Self.cachedIPA(for: app.bundleID))
        persist()
    }

    private func remember(_ file: URL, record: EmberWatchTrackedApp) throws {
        let manager = FileManager.default
        let destination = Self.cachedIPA(for: record.bundleID)
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if file.standardizedFileURL != destination.standardizedFileURL {
            let replacement = destination.deletingLastPathComponent().appendingPathComponent("stage-\(UUID()).ipa")
            try manager.copyItem(at: file, to: replacement)
            defer { try? manager.removeItem(at: replacement) }
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: replacement)
            } else {
                try manager.moveItem(at: replacement, to: destination)
            }
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                      ofItemAtPath: destination.path)
        }
        trackedApps.removeAll { $0.bundleID == record.bundleID }
        trackedApps.append(record)
        persist()
    }

    private static func validatedSource(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host == "raw.githubusercontent.com",
              url.pathExtension == "json", url.user == nil, url.password == nil else {
            throw EmberError.message("Use a public raw.githubusercontent.com HTTPS source.json URL.")
        }
        return url
    }

    private static func validatedDownload(_ value: String) throws -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host == "github.com",
              url.path.contains("/releases/download/"), url.pathExtension == "ipa",
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func isNewer(_ candidate: EmberWatchRelease, than current: EmberWatchRelease) -> Bool {
        compareVersions(candidate.buildVersion, current.buildVersion) > 0
    }

    private static func isNewer(_ candidate: EmberWatchRelease, than current: EmberWatchTrackedApp) -> Bool {
        compareVersions(candidate.buildVersion, current.feedBuild ?? current.build) > 0
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        guard !left.isEmpty, !right.isEmpty else { return lhs == rhs ? 0 : 1 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    private static func profileExpiration(_ profiles: [String: Data]) -> Date? {
        // Apple's CMS-wrapped mobileprovision commonly contains an XML plist.
        // Unknown formats fall back to an explicitly labelled seven-day estimate.
        let dates = profiles.values.compactMap { data -> Date? in
            let text = String(decoding: data, as: UTF8.self)
            guard let start = text.range(of: "<?xml"),
                  let end = text.range(of: "</plist>", range: start.lowerBound..<text.endIndex) else { return nil }
            let plist = Data(text[start.lowerBound..<end.upperBound].utf8)
            let values = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
            return values?["ExpirationDate"] as? Date
        }
        return dates.count == profiles.count ? dates.min() : nil
    }
}

private func emberSavedWatchIdentifier(_ key: String) -> String {
    if let saved = UserDefaults.standard.string(forKey: key), UUID(uuidString: saved) != nil { return saved }
    let id = UUID().uuidString
    UserDefaults.standard.set(id, forKey: key)
    return id
}

private func emberConsumeWatchString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { embersign_pair_free_string(pointer) }
    return String(cString: pointer)
}

private func emberDiscoverSingleWatch(deviceIP: String, port: UInt16) throws -> (String, String) {
    let pairing = try EmberPairingStore.read()
    guard pairing.kind == .remote else {
        throw EmberError.message("Import an RSD remote pairing record under Tools > Pairing file.")
    }
    var devices: UnsafeMutablePointer<CChar>?
    var phone: UnsafeMutablePointer<CChar>?
    var detail: UnsafeMutablePointer<CChar>?
    let code = EmberPairingStore.url.path.withCString { pairingPath in
        deviceIP.withCString { ip in
            embersign_watch_discover(pairingPath, ip, port, &phone, &devices, &detail)
        }
    }
    let phoneID = emberConsumeWatchString(phone)
    let list = emberConsumeWatchString(devices)
    let issue = emberConsumeWatchString(detail)
    guard code == 0 else { throw EmberError.message(issue ?? "Watch discovery failed") }
    guard let phoneID, !phoneID.isEmpty else { throw EmberError.message("Cannot identify the paired iPhone.") }
    let watches = (list ?? "").split(separator: ",").map(String.init)
    guard watches.count == 1 else {
        throw EmberError.message("Expected one reachable Apple Watch; found \(watches.count). Unlock the Watch and connect LocalDevVPN.")
    }
    return (phoneID, watches[0])
}

/// Inspect and transfer an already provisioned Watch app via the companion
/// proxy. A Watch signing profile is distinct from an iPhone signing profile.
struct EmberWatchSupportView: View {
    private enum IPASelection { case inspect, signed, provision }
    @State private var selection: IPASelection = .inspect
    @State private var isSelectingIPA = false
    @State private var isShowingOperationError = false
    @State private var isInspecting = false
    @State private var isDiscovering = false
    @State private var isInstalling = false
    @State private var watchIDs: [String] = []
    @State private var iphoneUDID: String?
    @State private var plan: EmberWatchBundlePlan?
    @State private var errorText: String?
    @ObservedObject private var watchProgress = EmberWatchProgress.shared
    @ObservedObject private var watchRefresh = EmberWatchRefreshManager.shared
    @AppStorage("EmberSign.jit.endpoint.deviceIP") private var deviceIP = "10.7.0.1"
    @AppStorage("EmberSign.jit.endpoint.port") private var devicePort = 49152
    @AppStorage("EmberSign.watch.feedURL") private var feedURL = EmberWatchRefreshManager.defaultSource

    var body: some View {
        List {
            Section("Watch IPA inspection") {
                Button {
                    selection = .inspect
                    isSelectingIPA = true
                } label: {
                    Label("Inspect an IPA", systemImage: "applewatch")
                }
                .disabled(isInspecting)

                if isInspecting {
                    HStack {
                        ProgressView()
                        Text("Checking bundled Watch targets…")
                    }
                }
                if let errorText {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Text("Checks Watch targets without changing or signing the imported IPA.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let plan {
                Section("Signing targets") {
                    if plan.hasWatchCompanion {
                        Label("Watch companion found", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("No Watch companion found", systemImage: "info.circle")
                    }
                    ForEach(plan.targets, id: \.bundleID) { target in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label(for: target.kind)).font(.headline)
                            Text(target.bundleID).font(.caption).textSelection(.enabled)
                            Text(target.relativePath).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }
            }

            Section("Paired Watch connection") {
                TextField("LocalDevVPN Device IP", text: $deviceIP)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Remote pairing port", value: $devicePort, format: .number)
                    .keyboardType(.numberPad)
                Button {
                    discoverWatches()
                } label: {
                    HStack {
                        Label("Find paired Apple Watch", systemImage: "applewatch")
                        Spacer()
                        if isDiscovering { ProgressView() }
                    }
                }.disabled(isDiscovering || isInstalling || watchRefresh.isWorking)
                ForEach(watchIDs, id: \.self) { id in
                    LabeledContent("Paired Watch UDID", value: id)
                        .font(.caption).textSelection(.enabled)
                }
                Text("Uses the existing EmberSign remote-pairing file. Keep the Watch unlocked, near the iPhone, and LocalDevVPN connected.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Sign and install Watch IPA") {
                NavigationLink { EmberIPAStudioView() } label: {
                    Label("Import and edit IPA before signing", systemImage: "slider.horizontal.3")
                }
                Text("For any Watch app, edit an unavailable Bundle ID here before requesting Apple provisioning. The iPhone, Watch and widget identifiers are remapped together.")
                    .font(.footnote).foregroundStyle(.secondary)
                if EmberAccountManager.shared.accounts.isEmpty {
                    NavigationLink {
                        EmberAccountsView()
                    } label: {
                        Label("Add Apple Account for Watch provisioning", systemImage: "person.crop.circle.badge.plus")
                    }
                } else {
                    Button {
                        selection = .provision
                        watchProgress.status = "Choose an unsigned iPhone IPA containing its Watch companion."
                        isSelectingIPA = true
                    } label: {
                        HStack {
                            Label("Provision, sign and install IPA", systemImage: "checkmark.shield")
                            Spacer()
                            if watchRefresh.isWorking { ProgressView() }
                        }
                    }
                    .disabled(watchIDs.count != 1 || iphoneUDID == nil || watchRefresh.isWorking || isInstalling || isDiscovering)
                    if watchRefresh.isWorking { ProgressView().padding(.vertical, 4) }
                    Text(watchProgress.status)
                        .font(.footnote).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let errorText {
                        Text(errorText)
                            .font(.footnote).foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Text("This route requests a development certificate through your selected Apple Account. It does not require a certificate in the imported Certificates list.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Find the paired Apple Watch, then choose an unsigned IPA containing its companion. EmberSign requests a separate development profile for each nested signing target, signs them, installs the iPhone app, then transfers the Watch app.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Watch refresh and GitHub updates") {
                if !watchRefresh.trackedApps.isEmpty {
                    ForEach(watchRefresh.trackedApps, id: \.bundleID) { saved in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(saved.feedBundleID ?? saved.bundleID) · build \(saved.feedBuild ?? saved.build)")
                                .font(.footnote.weight(.semibold))
                            Text("\(saved.expirationEstimated ? "Estimated expiry" : "Profile expiry"): \(saved.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(saved.sourceURL.isEmpty ? "No repo linked" : saved.sourceURL)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .swipeActions {
                            Button("Stop tracking", role: .destructive) { watchRefresh.stopTracking(saved) }
                        }
                    }
                    Toggle("Attempt automatic Watch refresh", isOn: Binding(
                        get: { watchRefresh.enabled }, set: { watchRefresh.enabled = $0 }
                    ))
                    Picker("Refresh when remaining", selection: Binding(
                        get: { watchRefresh.thresholdDays }, set: { watchRefresh.thresholdDays = $0 }
                    )) {
                        Text("1 day").tag(1)
                        Text("2 days").tag(2)
                        Text("3 days").tag(3)
                    }
                    Button {
                        Task { _ = await watchRefresh.refreshIfNeeded(force: true) }
                    } label: {
                        Label("Update or re-sign all Watch apps now", systemImage: "arrow.clockwise")
                    }.disabled(watchRefresh.isWorking || isInstalling)
                } else {
                    Text("No Watch IPA is tracked yet. Install one through the Apple Account option above or download it below. EmberSign will save the unsigned IPA after the Watch install succeeds.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                TextField("Public GitHub source.json URL", text: $feedURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    Task { await watchRefresh.checkForUpdates(sourceURL: feedURL) }
                } label: {
                    HStack {
                        Label("Check GitHub for Watch updates", systemImage: "arrow.down.circle")
                        Spacer()
                        if watchRefresh.isChecking { ProgressView() }
                    }
                }.disabled(watchRefresh.isChecking || watchRefresh.isWorking)
                .task { await watchRefresh.checkForUpdates(sourceURL: feedURL) }

                if let release = watchRefresh.latestRelease {
                    Text("Available: \(release.version) (build \(release.buildVersion))")
                        .font(.footnote)
                    Button {
                        Task {
                            do { try await watchRefresh.installLatestFromGitHub(sourceURL: feedURL) }
                            catch { showOperationError(error) }
                        }
                    } label: {
                        Label("Download, sign and install on iPhone + Watch", systemImage: "applewatch")
                    }.disabled(watchRefresh.isWorking || isInstalling)
                }
                Text(watchRefresh.status).font(.footnote).textSelection(.enabled)
                Text("An unsigned Watch release needs separate iPhone, Watch and widget profiles. Automatic refresh is best-effort: iOS may stop background work or the LocalDevVPN tunnel may be unavailable. If it does not complete, open EmberSign and refresh manually. Never uninstall the working Watch app first.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Install already signed Watch companion") {
                Button {
                    selection = .signed
                    isSelectingIPA = true
                } label: {
                    HStack {
                        Label("Install signed Watch IPA", systemImage: "square.and.arrow.down")
                        Spacer()
                        if isInstalling { ProgressView() }
                    }
                }.disabled(isDiscovering || isInstalling || watchRefresh.isWorking)
                Text(watchProgress.status).font(.footnote).textSelection(.enabled)
                Label("Experimental Watch transport", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("If your IPA was already signed with matching iPhone and Watch profiles, install its iPhone host through Apps, then select that same IPA here to transfer its Watch companion. This does not uninstall your existing Watch app.")
                Text("An iPhone-only FlareStore profile cannot sign the Watch. Use the Apple Account path above for an unsigned IPA.")
            }.font(.footnote)
        }
        .navigationTitle("Apple Watch")
        .sheet(isPresented: $isSelectingIPA) {
            EmberWatchNativeIPAPicker(
                onPick: { file in
                    isSelectingIPA = false
                    acceptSelectedIPA(file)
                },
                onCancel: {
                    isSelectingIPA = false
                    watchProgress.status = "IPA selection cancelled."
                }
            )
        }
        .alert("Apple Watch operation failed", isPresented: $isShowingOperationError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorText ?? "Unknown error")
        }
    }

    private func acceptSelectedIPA(_ file: URL) {
        guard file.pathExtension.lowercased() == "ipa" else {
            showOperationError(EmberError.message("Choose an .ipa file, not \(file.lastPathComponent)."))
            return
        }
        watchProgress.status = "Received \(file.lastPathComponent) from Files."
        switch selection {
        case .inspect:
            isInspecting = true
            errorText = nil
            plan = nil
            Task {
                do {
                    let inspected = try await Task.detached(priority: .userInitiated) {
                        try emberInspectWatchIPA(at: file)
                    }.value
                    plan = inspected
                } catch {
                    showOperationError(error)
                }
                isInspecting = false
            }
        case .signed:
            installSignedIPA(file)
        case .provision:
            signAndInstallIPA(file)
        }
    }

    private func showOperationError(_ error: Error) {
        errorText = error.localizedDescription
        watchProgress.status = "Watch operation failed. See error details."
        isShowingOperationError = true
    }

    private func discoverWatches() {
        guard !isDiscovering else { return }
        let endpoint = deviceIP
        let port = devicePort
        isDiscovering = true
        errorText = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[String], Error> in
                do {
                    let pairing = try EmberPairingStore.read()
                    guard pairing.kind == .remote else {
                        throw EmberError.message("Import an RSD remote pairing record in Tools > Pairing file.")
                    }
                    guard (1...65535).contains(port) else { throw EmberError.message("Invalid pairing port.") }
                    var devices: UnsafeMutablePointer<CChar>?
                    var phone: UnsafeMutablePointer<CChar>?
                    var detail: UnsafeMutablePointer<CChar>?
                    let code = EmberPairingStore.url.path.withCString { path in
                        endpoint.withCString { ip in
                            embersign_watch_discover(path, ip, UInt16(port), &phone, &devices, &detail)
                        }
                    }
                    let phoneID = Self.consumeNative(phone)
                    let list = Self.consumeNative(devices)
                    let issue = Self.consumeNative(detail)
                    guard code == 0 else { throw EmberError.message(issue ?? "Watch discovery failed") }
                    guard let phoneID, !phoneID.isEmpty else { throw EmberError.message("Cannot read this iPhone's UDID.") }
                    return .success([phoneID] + (list ?? "").split(separator: ",").map(String.init))
                } catch { return .failure(error) }
            }.value
            isDiscovering = false
            switch outcome {
            case .success(let ids):
                iphoneUDID = ids.first
                watchIDs = Array(ids.dropFirst())
                watchProgress.status = watchIDs.isEmpty ? "No Apple Watch is paired or reachable." : "Found \(watchIDs.count) paired Apple Watch device(s)."
            case .failure(let error):
                showOperationError(error)
            }
        }
    }

    private func installSignedIPA(_ file: URL) {
        guard !isInstalling else { return }
        let endpoint = deviceIP
        let port = devicePort
        isInstalling = true
        errorText = nil
        watchProgress.status = "Checking Watch provisioning and code signatures…"
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do {
                    guard (1...65535).contains(port) else { throw EmberError.message("Invalid remote pairing port.") }
                    let pairing = try EmberPairingStore.read()
                    guard pairing.kind == .remote else {
                        throw EmberError.message("Import an RSD remote pairing record in Tools > Pairing file.")
                    }
                    let hostID = Self.savedWatchIdentifier("EmberSign.watch.hostID")
                    let systemBUID = Self.savedWatchIdentifier("EmberSign.watch.systemBUID")
                    let message = try emberInstallSignedWatchIPA(
                        at: file, pairingURL: EmberPairingStore.url,
                        deviceIP: endpoint, devicePort: UInt16(port),
                        hostID: hostID, systemBUID: systemBUID
                    )
                    return .success(message)
                } catch { return .failure(error) }
            }.value
            isInstalling = false
            switch outcome {
            case .success(let message): watchProgress.status = message
            case .failure(let error):
                showOperationError(error)
            }
        }
    }

    private func signAndInstallIPA(_ file: URL) {
        guard !watchRefresh.isWorking else { return }
        errorText = nil
        Task {
            do {
                try await watchRefresh.installAndTrack(file: file, sourceURL: feedURL)
            } catch {
                showOperationError(error)
                EmberErrorCenter.shared.record(error, operation: "Apple Watch installation")
            }
        }
    }

    nonisolated private static func savedWatchIdentifier(_ key: String) -> String {
        if let saved = UserDefaults.standard.string(forKey: key), UUID(uuidString: saved) != nil { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    nonisolated private static func consumeNative(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { embersign_pair_free_string(pointer) }
        return String(cString: pointer)
    }

    private func label(for kind: EmberWatchBundlePlan.Target.Kind) -> String {
        switch kind {
        case .iphoneApp: "iPhone app"
        case .watchApp: "Watch app"
        case .watchWidget: "Watch widget"
        }
    }

}

private struct EmberWatchNativeIPAPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Use the system's broad file type, then validate .ipa explicitly.
        // Dynamic IPA UTTypes can prevent the SwiftUI file importer from
        // delivering a selection for an otherwise valid archive.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let first = urls.first else { onCancel(); return }
            onPick(first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

private func emberInstallSignedWatchIPA(
    at file: URL, pairingURL: URL, deviceIP: String, devicePort: UInt16,
    hostID: String, systemBUID: String
) throws -> String {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("EmberWatchTransfer-\(UUID())", isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let (host, plan) = try emberExtractWatchIPA(at: file, into: root)
    try emberVerifySignedWatch(host: host, plan: plan)
    return try emberStreamWatchBundle(host: host, plan: plan, pairingURL: pairingURL,
                                     deviceIP: deviceIP, devicePort: devicePort,
                                     hostID: hostID, systemBUID: systemBUID)
}

private func emberExtractWatchIPA(at file: URL, into root: URL) throws -> (URL, EmberWatchBundlePlan) {
    guard file.pathExtension.lowercased() == "ipa" else { throw EmberError.message("Select an .ipa archive.") }
    let access = file.startAccessingSecurityScopedResource()
    defer { if access { file.stopAccessingSecurityScopedResource() } }
    let manager = FileManager.default
    let copied = root.appendingPathComponent("original.ipa")
    try manager.copyItem(at: file, to: copied)
    let archive = try Archive(url: copied, accessMode: .read)
    let unpacked = root.appendingPathComponent("contents", isDirectory: true)
    try manager.createDirectory(at: unpacked, withIntermediateDirectories: true)
    var seen = Set<String>()
    var total: UInt64 = 0
    for entry in archive {
        let path = entry.path
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
            throw EmberWatchBundleError.unsafeArchivePath(path)
        }
        guard pieces.first == "Payload" else { continue }
        // Standard IPA ZIPs may explicitly include the Payload/ directory.
        // The root directory is safe and has no content to extract.
        if entry.type == .directory && pieces.count == 1 { continue }
        guard pieces.count >= 2, pieces[1].hasSuffix(".app") else {
            throw EmberWatchBundleError.unsafeArchivePath(path)
        }
        if entry.type == .directory { continue }
        guard entry.type == .file, seen.insert(path).inserted else {
            throw EmberWatchBundleError.unsafeArchivePath(path)
        }
        let size = UInt64(entry.uncompressedSize)
        total += size
        guard size <= 128 * 1024 * 1024, total <= 1024 * 1024 * 1024 else {
            throw EmberError.message("Watch IPA exceeds safe extraction limits.")
        }
        let target = unpacked.appendingPathComponent(path)
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try archive.extract(entry, to: target)
    }
    let hostBundles = try manager.contentsOfDirectory(at: unpacked.appendingPathComponent("Payload"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "app" }
    guard hostBundles.count == 1, let host = hostBundles.first else {
        throw EmberError.message("Expected exactly one signed iPhone host app in Payload/.")
    }
    let plan = try EmberWatchBundleInspector.inspect(iphoneApp: host)
    return (host, plan)
}

private func emberVerifySignedWatch(host: URL, plan: EmberWatchBundlePlan) throws {
    let manager = FileManager.default
    let watches = plan.targets.filter { $0.kind == .watchApp }
    guard watches.count == 1 else {
        throw EmberError.message("Expected exactly one Apple Watch companion in the IPA.")
    }
    for target in plan.targets {
        let bundle = host.appendingPathComponent(target.relativePath)
        guard manager.fileExists(atPath: bundle.appendingPathComponent("embedded.mobileprovision").path),
              manager.fileExists(atPath: bundle.appendingPathComponent("_CodeSignature/CodeResources").path) else {
            throw EmberWatchBundleError.missingProfile(target.bundleID)
        }
    }
}

private func emberStreamWatchBundle(
    host: URL, plan: EmberWatchBundlePlan, pairingURL: URL,
    deviceIP: String, devicePort: UInt16, hostID: String, systemBUID: String
) throws -> String {
    guard let watch = plan.targets.first(where: { $0.kind == .watchApp }) else {
        throw EmberError.message("The signed IPA contains no Watch app.")
    }
    let watchURL = host.appendingPathComponent(watch.relativePath)
    var nativeError: UnsafeMutablePointer<CChar>?
    let result = pairingURL.path.withCString { pairing in
        deviceIP.withCString { ip in
            hostID.withCString { host in
                systemBUID.withCString { buid in
                    watchURL.path.withCString { app in
                        embersign_watch_install_signed(pairing, ip, devicePort, host, buid, app, { status, _ in
                            guard let status else { return }
                            let message = String(cString: status)
                            Task { @MainActor in EmberWatchProgress.shared.status = message }
                        }, nil, &nativeError)
                    }
                }
            }
        }
    }
    let failureText: String? = nativeError.map { pointer in
        defer { embersign_pair_free_string(pointer) }
        return String(cString: pointer)
    }
    guard result == 0 else { throw EmberError.message(failureText ?? "Watch transfer failed") }
    return "Watch transfer completed. Confirm the app opens on your Watch and its widgets appear."
}

private func emberSignWatchIPA(
    host: URL, plan: EmberWatchBundlePlan,
    identity: EmberWatchSigningIdentity, root: URL
) throws -> URL {
    try plan.validateProfiles(identity.profiles)
    let fm = FileManager.default
    let certificate = root.appendingPathComponent("WatchSigning.p12")
    try identity.p12.write(to: certificate, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    var profilePaths: [String] = []
    for (index, target) in plan.targets.enumerated() {
        guard let data = identity.profiles[target.bundleID], !data.isEmpty else {
            throw EmberWatchBundleError.missingProfile(target.bundleID)
        }
        let profile = root.appendingPathComponent("WatchProfile-\(index).mobileprovision")
        try data.write(to: profile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        profilePaths.append(profile.path)
    }
    // The pinned Zsign C++ engine matches profiles by bundle identifier.
    // EmberSign's build-time shim exposes the existing multi-profile engine
    // through a newline-delimited provisionPath. Single-profile callers are
    // untouched and each nested bundle receives its OWN embedded profile.
    guard Zsign.sign(appPath: host.path, provisionPath: profilePaths.joined(separator: "\n"),
                     p12Path: certificate.path, p12Password: "", removeProvision: false,
                     completion: { _ in }) else {
        throw EmberError.message("Zsign rejected the iPhone, Watch or widget signing targets.")
    }
    try emberVerifySignedWatch(host: host, plan: plan)
    // Zsign uses each profile's entitlements by default. Confirm it retained the
    // provisioned probe group on every architecture before packaging/installing.
    if plan.targets.first?.bundleID == "dev.watchlink.companion" {
        for target in plan.targets {
            guard let profile = identity.profiles[target.bundleID] else {
                throw EmberWatchBundleError.missingProfile(target.bundleID)
            }
            let groups = try EmberWatchLinkProbe.groups(in: EmberWatchLinkProbe.profileEntitlements(profile))
            guard let group = groups.first(where: { $0.hasSuffix(".watchlink.probe") }) else {
                throw EmberWatchLinkProbe.Failure.missingGroup
            }
            let bundle = host.appendingPathComponent(target.relativePath)
            let metadata = try Data(contentsOf: bundle.appendingPathComponent("Info.plist"))
            guard let info = try PropertyListSerialization.propertyList(from: metadata, format: nil) as? [String: Any],
                  let name = info["CFBundleExecutable"] as? String,
                  !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
                throw EmberWatchLinkProbe.Failure.invalidExecutable
            }
            try EmberWatchLinkProbe.requireSignedGroup(group,
                executable: Data(contentsOf: bundle.appendingPathComponent(name), options: .mappedIfSafe))
        }
    }

    let contents = root.appendingPathComponent("contents", isDirectory: true)
    let signed = root.appendingPathComponent("EmberWatch-signed.ipa")
    let archive = try Archive(url: signed, accessMode: .create)
    guard let enumerator = fm.enumerator(at: contents, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
        throw EmberError.message("Cannot enumerate the signed app for packaging.")
    }
    var count = 0
    for case let item as URL in enumerator {
        let resource = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard resource.isSymbolicLink != true else {
            throw EmberError.message("Signed IPA contains an unsupported symbolic link.")
        }
        guard resource.isRegularFile == true else { continue }
        let relative = String(item.path.dropFirst(contents.path.count + 1))
        guard relative.hasPrefix("Payload/") else { continue }
        try archive.addEntry(with: relative, relativeTo: contents, compressionMethod: .deflate)
        count += 1
    }
    guard count > 0 else { throw EmberError.message("Signed IPA has no files to package.") }
    return signed
}

private func emberInspectWatchIPA(at file: URL) throws -> EmberWatchBundlePlan {
    guard file.pathExtension.lowercased() == "ipa" else {
        throw EmberError.message("Select an .ipa file.")
    }
    let access = file.startAccessingSecurityScopedResource()
    defer { if access { file.stopAccessingSecurityScopedResource() } }
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("EmberWatchInspection-\(UUID())", isDirectory: true)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }

    let localIPA = directory.appendingPathComponent("import.ipa")
    try fm.copyItem(at: file, to: localIPA)
    let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
    try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
    // Read only Info.plist entries from an untrusted archive. In particular,
    // never pass the entire IPA to Zip.unzipFile, whose pinned release lacks
    // safe traversal handling for arbitrary archive paths.
    let archive = try Archive(url: localIPA, accessMode: .read)
    var extracted = Set<String>()
    for entry in archive where entry.type == .file {
        guard try EmberWatchArchivePolicy.shouldReadInfoPlist(entry.path, size: UInt64(entry.uncompressedSize)) else {
            continue
        }
        guard extracted.insert(entry.path).inserted else {
            throw EmberWatchBundleError.unsafeArchivePath("Duplicate entry: \(entry.path)")
        }
        let target = unpacked.appendingPathComponent(entry.path)
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            guard data.count + chunk.count <= 1_048_576 else {
                throw EmberWatchBundleError.oversizedInfoPlist(entry.path)
            }
            data.append(chunk)
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }
    let payload = unpacked.appendingPathComponent("Payload")
    let apps = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "app" }
    guard apps.count == 1, let app = apps.first else {
        throw EmberError.message("Expected exactly one iPhone app in Payload/.")
    }
    return try EmberWatchBundleInspector.inspect(iphoneApp: app)
}
