import Foundation
import SwiftUI
import IDeviceSwift
import IDevice
import Darwin

struct EmberInactiveSlot: Identifiable, Codable {
    let id: String
    let name: String
    let teamID: String
    let savedAt: Date
    let profiles: [Data]
    var deactivated: Bool
}

private enum EmberSlotError: LocalizedError {
    case message(String)
    static func fromFFI(_ pointer: UnsafeMutablePointer<IdeviceFfiError>) -> EmberSlotError {
        let message = pointer.pointee.message.map { String(cString: $0) } ?? "Unknown device service error."
        let code = pointer.pointee.code
        idevice_error_free(pointer)
        return .message("Device service (\(code)): " + message)
    }
    var errorDescription: String? {
        if case .message(let detail) = self { return detail }
        return "Provisioning profile operation failed."
    }
}

/// A protected local copy of the exact profiles is saved before changing any on-device state.
/// No certificate/private key is stored here, and no app binary is uninstalled.
private enum EmberSlotStore {
    private static var location: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EmberSign-InactiveProfiles.json")
    }
    static func load() -> [EmberInactiveSlot] {
        guard let data = try? Data(contentsOf: location) else { return [] }
        return (try? JSONDecoder().decode([EmberInactiveSlot].self, from: data)) ?? []
    }
    static func save(_ records: [EmberInactiveSlot]) throws {
        let data = try JSONEncoder().encode(records)
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: location, options: [.atomic, .completeFileProtection])
    }
}

/// Uses libidevice's own misagent FFI (already bundled with EmberSign's IDeviceKit).
/// This operates on *installed provisioning profiles*, never Apple developer portal App IDs.
private enum EmberSlotBridge {
    private static func withClient<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        let path = HeartbeatManager.pairingFile()
        guard FileManager.default.fileExists(atPath: path) else {
            throw EmberSlotError.message("Import a valid device pairing file first.")
        }
        let heartbeat = HeartbeatManager.shared
        var client: OpaquePointer?
        if #available(iOS 17.4, *) {
            var pairing: OpaquePointer?
            if let failure = rp_pairing_file_read(path, &pairing) {
                throw EmberSlotError.fromFFI(failure)
            }
            guard let pairing else { throw EmberSlotError.message("Unable to read remote pairing record.") }
            defer { rp_pairing_file_free(pairing) }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            let configuredPort = UserDefaults.standard.integer(forKey: "EmberSign.jit.endpoint.port")
            let port = configuredPort == 0 ? 49152 : configuredPort
            guard (1...65535).contains(port) else { throw EmberSlotError.message("Invalid LocalDevVPN device port.") }
            addr.sin_port = CFSwapInt16HostToBig(UInt16(port))
            let host = UserDefaults.standard.string(forKey: "EmberSign.jit.endpoint.deviceIP") ?? "10.7.0.1"
            guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
                throw EmberSlotError.message("Invalid LocalDevVPN device IP.")
            }
            var adapter: OpaquePointer?
            var handshake: OpaquePointer?
            let tunnelError = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                                            "EmberSign", pairing, nil, nil, &adapter, &handshake)
                }
            }
            if let tunnelError { throw EmberSlotError.fromFFI(tunnelError) }
            guard let adapter, let handshake else { throw EmberSlotError.message("Remote pairing tunnel unavailable.") }
            defer { rsd_handshake_free(handshake); adapter_free(adapter) }
            if let error = misagent_connect_rsd(adapter, handshake, &client) { throw EmberSlotError.fromFFI(error) }
            guard let client else { throw EmberSlotError.message("Could not open provisioning profile service.") }
            defer { misagent_client_free(client) }
            return try operation(client)
        } else {
            guard heartbeat.checkSocketConnection().isConnected else {
                throw EmberSlotError.message("LocalDevVPN connection unavailable.")
            }
            var pairing: OpaquePointer?
            if let error = idevice_pairing_file_read(path, &pairing) { throw EmberSlotError.fromFFI(error) }
            guard let pairing else { throw EmberSlotError.message("Cannot read the pairing record.") }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = CFSwapInt16HostToBig(heartbeat.port)
            guard inet_pton(AF_INET, heartbeat.ipAddress, &addr.sin_addr) == 1 else {
                idevice_pairing_file_free(pairing)
                throw EmberSlotError.message("Invalid local device IP.")
            }
            var provider: OpaquePointer?
            let providerError = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    idevice_tcp_provider_new($0, pairing, "EmberSign", &provider)
                }
            }
            if let providerError {
                idevice_pairing_file_free(pairing)
                throw EmberSlotError.fromFFI(providerError)
            }
            guard let provider else { throw EmberSlotError.message("Cannot connect to the paired device.") }
            defer { idevice_provider_free(provider) }
            if let error = misagent_connect(provider, &client) { throw EmberSlotError.fromFFI(error) }
            guard let client else { throw EmberSlotError.message("Provisioning profile service unavailable.") }
            defer { misagent_client_free(client) }
            return try operation(client)
        }
    }

    static func read() throws -> [Data] {
        try withClient { client in
            var pointers: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
            var sizes: UnsafeMutablePointer<Int>?
            var count = 0
            if let error = misagent_copy_all(client, &pointers, &sizes, &count) {
                throw EmberSlotError.fromFFI(error)
            }
            defer { misagent_free_profiles(pointers, sizes, count) }
            guard count >= 0, count <= 500, let pointers, let sizes else { return [] }
            return (0..<count).compactMap { index -> Data? in
                guard let p = pointers[index], sizes[index] > 0, sizes[index] < 1_000_000 else { return nil }
                return Data(bytes: p, count: sizes[index])
            }
        }
    }

    static func remove(uuids: [String]) throws {
        try withClient { client in
            for uuid in uuids {
                if let error = misagent_remove(client, uuid) { throw EmberSlotError.fromFFI(error) }
            }
        }
    }

    static func restore(_ profiles: [Data]) throws {
        try withClient { client in
            for profile in profiles {
                let error = profile.withUnsafeBytes { raw in
                    misagent_install(client, raw.bindMemory(to: UInt8.self).baseAddress, profile.count)
                }
                if let error { throw EmberSlotError.fromFFI(error) }
            }
        }
    }
}

@MainActor
final class EmberDeviceAppsModel: NSObject, ObservableObject, InstallationProxyAppsDelegate {
    @Published var apps: [AppInfo] = []
    @Published private(set) var inactive: [EmberInactiveSlot] = EmberSlotStore.load()
    @Published var isLoading = false
    @Published var status = "Connect LocalDevVPN and import this device's pairing file to scan installed apps."
    private let proxy = InstallationAppProxy()

    override init() {
        super.init()
        proxy.delegate = self
    }

    nonisolated func updateApplications(with apps: [AppInfo]) {
        Task { @MainActor [weak self] in
            self?.apps = apps.sorted {
                ($0.CFBundleDisplayName ?? $0.CFBundleName ?? $0.CFBundleIdentifier ?? "")
                    .localizedCaseInsensitiveCompare($1.CFBundleDisplayName ?? $1.CFBundleName ?? $1.CFBundleIdentifier ?? "") == .orderedAscending
            }
            self?.isLoading = false
            self?.status = "Found \(apps.count) apps through the paired-device service."
        }
    }

    func scan() async {
        isLoading = true
        status = "Reading installed app metadata..."
        do {
            try await proxy.listApps()
        } catch {
            isLoading = false
            status = error.localizedDescription
            EmberErrorCenter.shared.record(error, operation: "Scan installed apps")
        }
    }

    func uninstall(_ app: AppInfo, removePortalRecords: Bool) async {
        guard let bundleID = app.CFBundleIdentifier else { return }
        guard !hasSavedProfiles(bundleID) else {
            status = "Restore the app's saved provisioning profiles before uninstalling it. Otherwise its data may be lost."
            return
        }
        isLoading = true
        do {
            try await InstallationAppProxy.deleteApp(for: bundleID)
            if removePortalRecords {
                try await EmberAccountManager.shared.revokePortalRecords(bundleID: bundleID, teamID: app.teamIdentifier)
            }
            status = removePortalRecords
                ? "Uninstalled \(app.displayName) and requested removal of its provisioning profile/App ID."
                : "Uninstalled \(app.displayName)."
            try await proxy.listApps()
        } catch {
            isLoading = false
            status = error.localizedDescription
            EmberErrorCenter.shared.record(error, operation: removePortalRecords ? "Uninstall and revoke app" : "Uninstall app")
        }
    }

    func isFreeTeam(_ teamID: String?) -> Bool {
        guard let teamID,
              let account = EmberAccountManager.shared.account(forTeamID: teamID),
              let team = account.teams.first(where: { $0.identifier == teamID }) else {
            return false
        }
        return team.type == .free
    }

    func hasSavedProfiles(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return inactive.contains(where: { $0.id == bundleID })
    }

    func deactivate(_ app: AppInfo) async {
        guard !isLoading,
              let bundleID = app.CFBundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              let teamID = app.teamIdentifier, isFreeTeam(teamID),
              !hasSavedProfiles(bundleID) else {
            status = "Only installed apps belonging to a linked free Apple development team can be deactivated."
            return
        }
        isLoading = true
        status = "Reading installed provisioning profiles for \(app.displayName)..."
        do {
            let rawProfiles = try await Task.detached(priority: .userInitiated) {
                try EmberSlotBridge.read()
            }.value
            let matching = rawProfiles.compactMap { try? EmberIOSProvisionProfile.parse($0) }
                .filter { profile in
                    // An app extension can have a similar bundle prefix but be a different
                    // installed product. Do not modify it without a verified IPA manifest.
                    profile.team == teamID && profile.applicationPattern == teamID + "." + bundleID
                }
            guard matching.contains(where: { $0.applicationPattern == teamID + "." + bundleID }) else {
                throw EmberSlotError.message("No exact installed provisioning profile for \(bundleID). Nothing was changed.")
            }
            let record = EmberInactiveSlot(
                id: bundleID, name: app.displayName, teamID: teamID,
                savedAt: Date(), profiles: matching.map(\.data), deactivated: false
            )
            // Persist the original signed profiles *before* changing the device.
            // A pending record remains available even if recovery is interrupted.
            inactive.append(record)
            do {
                try EmberSlotStore.save(inactive)
            } catch {
                inactive.removeAll { $0.id == bundleID }
                throw error
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    do {
                        try EmberSlotBridge.remove(uuids: matching.map(\.id))
                        let remaining = try EmberSlotBridge.read()
                        let remainingIDs = Set(remaining.compactMap {
                            try? EmberIOSProvisionProfile.parse($0).id
                        })
                        guard Set(matching.map(\.id)).isDisjoint(with: remainingIDs) else {
                            throw EmberSlotError.message("Device still reports installed profiles after deactivation.")
                        }
                    } catch {
                        // If any of the removals failed partway through, put all profiles back.
                        try? EmberSlotBridge.restore(matching.map(\.data))
                        throw error
                    }
                }.value
                inactive = inactive.map { saved in
                    var saved = saved
                    if saved.id == bundleID { saved.deactivated = true }
                    return saved
                }
                try EmberSlotStore.save(inactive)
                status = "Removed \(matching.count) installed profile(s) for \(app.displayName). Reactivate restores them. App data was not backed up; verify the Apple 3-app slot count before relying on it."
            } catch {
                status = "Profile operation incomplete. The original profiles are saved under Reactivate/Recover."
                throw error
            }
        } catch {
            status += " " + error.localizedDescription
            EmberErrorCenter.shared.record(error, operation: "Deactivate free-team app")
        }
        isLoading = false
    }

    func reactivate(_ record: EmberInactiveSlot) async {
        guard !isLoading else { return }
        isLoading = true
        status = "Restoring saved provisioning profiles for \(record.name)..."
        do {
            try await Task.detached(priority: .userInitiated) {
                try EmberSlotBridge.restore(record.profiles)
            }.value
            let installed = try await Task.detached(priority: .userInitiated) {
                try EmberSlotBridge.read()
            }.value
            let profileIDs = Set(installed.compactMap { try? EmberIOSProvisionProfile.parse($0).id })
            let required = Set(record.profiles.compactMap { try? EmberIOSProvisionProfile.parse($0).id })
            guard required.isSubset(of: profileIDs) else {
                throw EmberSlotError.message("Profile restoration was not verified. Keep the recovery record.")
            }
            let previous = inactive
            inactive.removeAll { $0.id == record.id }
            do {
                try EmberSlotStore.save(inactive)
            } catch {
                inactive = previous
                throw error
            }
            status = "Restored \(required.count) provisioning profile(s) for \(record.name). If the app was uninstalled elsewhere, reinstalling its IPA may still be necessary."
        } catch {
            status = "Reactivate failed: " + error.localizedDescription
            EmberErrorCenter.shared.record(error, operation: "Reactivate free-team app")
        }
        isLoading = false
    }
}

private extension AppInfo {
    var displayName: String { CFBundleDisplayName ?? CFBundleName ?? CFBundleIdentifier ?? "Unknown" }
    var teamIdentifier: String? {
        if let value = Entitlements?["com.apple.developer.team-identifier"]?.value as? String { return value }
        if let value = Entitlements?["application-identifier"]?.value as? String { return value.split(separator: ".").first.map(String.init) }
        return nil
    }
    var applicationIdentifier: String? { Entitlements?["application-identifier"]?.value as? String }
    var getTaskAllow: Bool? { Entitlements?["get-task-allow"]?.value as? Bool }
}

struct EmberDeviceAppsView: View {
    @StateObject private var model = EmberDeviceAppsModel()
    @ObservedObject private var accounts = EmberAccountManager.shared
    @ObservedObject private var jit = EmberJITService.shared
    @ObservedObject private var refresh = EmberAutoRefreshManager.shared
    @State private var selected: AppInfo?
    @State private var pendingRemoval: AppInfo?
    @State private var pendingDeactivation: AppInfo?
    @State private var pendingReactivation: EmberInactiveSlot?

    var body: some View {
        List {
            Section {
                Button { Task { await model.scan() } } label: {
                    HStack { Label("Scan device", systemImage: "arrow.clockwise"); Spacer(); if model.isLoading { ProgressView() } }
                }.disabled(model.isLoading)
                Text(model.status).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            } footer: {
                Text("The list comes from Apple's paired-device installation service, not from private app folders. A working pairing tunnel is required.")
            }
            if !model.inactive.isEmpty {
                Section("Saved provisioning profiles / recovery") {
                    ForEach(model.inactive) { record in
                        Button { pendingReactivation = record } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(record.name, systemImage: record.deactivated ? "checkmark.shield" : "exclamationmark.triangle")
                                    .foregroundStyle(.primary)
                                Text(record.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(record.deactivated ? "Restore previously removed profiles" : "Pending operation, recover saved profiles")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            Section("Installed apps") {
                ForEach(model.apps) { app in
                    Button { selected = app } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.displayName).foregroundStyle(.primary)
                            Text(app.CFBundleIdentifier ?? "Unknown bundle ID").font(.caption.monospaced()).foregroundStyle(.secondary)
                            HStack {
                                Text("v\(app.CFBundleShortVersionString ?? "?") (\(app.CFBundleVersion ?? "?"))")
                                if let team = app.teamIdentifier {
                                    Text("•")
                                    Text(accounts.account(forTeamID: team)?.auth.account.appleID ?? team)
                                }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        if !model.hasSavedProfiles(app.CFBundleIdentifier) {
                            Button(role: .destructive) { pendingRemoval = app } label: { Label("Remove", systemImage: "trash") }
                        }
                        if model.isFreeTeam(app.teamIdentifier),
                           !model.hasSavedProfiles(app.CFBundleIdentifier),
                           app.CFBundleIdentifier != Bundle.main.bundleIdentifier {
                            Button { pendingDeactivation = app } label: {
                                Label("Suspend profiles (experimental)", systemImage: "pause.circle")
                            }.tint(.orange)
                        }
                    }
                }
            }
            Section {
                Text("Experimental profile backup/removal only. This does not deactivate an app like Zeus or free an installed-app slot. The app stays installed. Do not use this to make room for another app. Purchased/enterprise certificate apps are excluded.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Installed apps")
        .task { await model.scan() }
        .sheet(item: $selected) { app in
            NavigationStack {
                List {
                    Section("Application") {
                        LabeledContent("Name", value: app.displayName)
                        LabeledContent("Bundle ID", value: app.CFBundleIdentifier ?? "Unknown")
                        LabeledContent("Version", value: app.CFBundleShortVersionString ?? "Unknown")
                        LabeledContent("Build", value: app.CFBundleVersion ?? "Unknown")
                        LabeledContent("Minimum iOS", value: app.MinimumOSVersion ?? "Unknown")
                    }
                    Section("Signing") {
                        LabeledContent("Signer", value: app.SignerIdentity ?? "Unknown")
                        LabeledContent("Team ID", value: app.teamIdentifier ?? "Unknown")
                        LabeledContent("Account", value: accounts.account(forTeamID: app.teamIdentifier)?.auth.account.appleID ?? "Not matched")
                        LabeledContent("Application ID", value: app.applicationIdentifier ?? "Unknown")
                        LabeledContent("JIT entitlement", value: app.getTaskAllow == true ? "Enabled" : "Not enabled")
                    }
                    if let bundleID = app.CFBundleIdentifier,
                       bundleID != Bundle.main.bundleIdentifier {
                        Section("Launch from EmberSign") {
                            Toggle("Always open with JIT", isOn: Binding(
                                get: { jit.prefersJIT(for: bundleID) },
                                set: { jit.setPrefersJIT($0, for: bundleID) }
                            ))
                            Button {
                                selected = nil
                                Task { await jit.openFromLibrary(bundleID) }
                            } label: {
                                Label(jit.prefersJIT(for: bundleID) ? "Open with JIT" : "Open without JIT",
                                      systemImage: jit.prefersJIT(for: bundleID) ? "bolt.fill" : "play.fill")
                            }.disabled(jit.isBusy)
                            Text("The JIT preference applies only when opening through EmberSign. iOS Home Screen launches cannot be intercepted. Both actions require a working paired-device tunnel on iOS 17.4+.")
                                .font(.footnote).foregroundStyle(.secondary)
                            if !jit.status.isEmpty { Text(jit.status).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if let bundleID = app.CFBundleIdentifier,
                       accounts.account(forTeamID: app.teamIdentifier) != nil,
                       refresh.trackedApps().contains(where: { $0.id == bundleID }) {
                        Section("Refresh signing") {
                            Button {
                                selected = nil
                                Task { _ = await refresh.refresh(bundleID: bundleID) }
                            } label: { Label("Re-sign and reinstall this app", systemImage: "arrow.triangle.2.circlepath") }
                                .disabled(refresh.isRunning)
                        } footer: {
                            Text("Uses the Apple Account EmberSign originally linked to this app. It does not replace a purchased certificate or change the app's signing team.")
                        }
                    }
                    if model.isFreeTeam(app.teamIdentifier) {
                        Section {
                            if model.hasSavedProfiles(app.CFBundleIdentifier) {
                                Text("This app already has saved profiles. Restore them from the Deactivated / recovery section.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else if app.CFBundleIdentifier != Bundle.main.bundleIdentifier {
                                Button {
                                    pendingDeactivation = app
                                    selected = nil
                                } label: { Label("Suspend profiles (experimental)", systemImage: "pause.circle") }
                            }
                        } footer: {
                            Text("Does not free a three-app slot. The app's data is not backed up. Profile removal is reversible using the stored originals, but this is not the Zeus backup/deactivation workflow.")
                        }
                    }
                    if !model.hasSavedProfiles(app.CFBundleIdentifier) {
                        Section {
                            Button(role: .destructive) { pendingRemoval = app; selected = nil } label: { Label("Uninstall or revoke", systemImage: "trash") }
                        } footer: {
                            Text("Removing the portal App ID does not guarantee immediate quota recovery. Apple controls the Personal Team seven-day registration window.")
                        }
                    }
                }
                .navigationTitle(app.displayName)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { selected = nil } } }
            }
        }
        .confirmationDialog("Remove \(pendingRemoval?.displayName ?? "app")?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible) {
            if let app = pendingRemoval {
                Button("Uninstall only", role: .destructive) {
                    pendingRemoval = nil
                    Task { await model.uninstall(app, removePortalRecords: false) }
                }
                Button("Uninstall and remove signing records", role: .destructive) {
                    pendingRemoval = nil
                    Task { await model.uninstall(app, removePortalRecords: true) }
                }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        }
        .confirmationDialog("Suspend profiles for \(pendingDeactivation?.displayName ?? "app")?", isPresented: Binding(
            get: { pendingDeactivation != nil },
            set: { if !$0 { pendingDeactivation = nil } }
        ), titleVisibility: .visible) {
            if let app = pendingDeactivation {
                Button("Save and remove profiles") {
                    pendingDeactivation = nil
                    Task { await model.deactivate(app) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDeactivation = nil }
        } message: {
            Text("Experimental. This saves and removes signing profiles only. It DOES NOT free an installed-app slot. No app data backup or uninstall occurs. Do not delete EmberSign or its documents before restoring the profiles.")
        }
        .confirmationDialog("Restore \(pendingReactivation?.name ?? "app")?", isPresented: Binding(
            get: { pendingReactivation != nil },
            set: { if !$0 { pendingReactivation = nil } }
        ), titleVisibility: .visible) {
            if let record = pendingReactivation {
                Button(record.deactivated ? "Reactivate profiles" : "Recover saved profiles") {
                    pendingReactivation = nil
                    Task { await model.reactivate(record) }
                }
            }
            Button("Cancel", role: .cancel) { pendingReactivation = nil }
        } message: {
            Text("Restore the saved provisioning profiles to this iPhone. This cannot restore app data if the app was uninstalled.")
        }
    }
}
