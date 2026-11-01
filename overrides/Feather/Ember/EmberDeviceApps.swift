import Foundation
import SwiftUI
import IDeviceSwift
import IDevice
import Darwin
import UniformTypeIdentifiers

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
enum EmberSlotStore {
    private static var location: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EmberSign-InactiveProfiles.json")
    }
    static func load() throws -> [EmberInactiveSlot] {
        guard FileManager.default.fileExists(atPath: location.path) else { return [] }
        // Fail closed when the protected recovery file cannot be read or decoded.
        // Treating it as an empty list could overwrite the only recovery copy.
        let data = try Data(contentsOf: location)
        let records = try JSONDecoder().decode([EmberInactiveSlot].self, from: data)
        guard Set(records.map(\.id)).count == records.count else {
            throw EmberSlotError.message("Duplicate app IDs in saved recovery profiles. No profiles were changed.")
        }
        return records
    }

    static func hasSavedProfiles(for bundleID: String) throws -> Bool {
        try load().contains { $0.id == bundleID }
    }

    static func importRecovery(_ incoming: [EmberInactiveSlot]) throws -> [EmberInactiveSlot] {
        guard !incoming.isEmpty, incoming.count <= 100,
              Set(incoming.map(\.id)).count == incoming.count else {
            throw EmberSlotError.message("Recovery archive is empty, duplicated, or unexpectedly large.")
        }
        var current = try load()
        for record in incoming {
            guard !record.profiles.isEmpty, record.profiles.count <= 20 else {
                throw EmberSlotError.message("Invalid profile count for \(record.name).")
            }
            let parsed = try record.profiles.map { try EmberIOSProvisionProfile.parse($0) }
            guard parsed.allSatisfy({ $0.team == record.teamID &&
                $0.applicationPattern == record.teamID + "." + record.id }) else {
                throw EmberSlotError.message("Recovery archive includes profiles not belonging to \(record.id).")
            }
            if let existing = current.first(where: { $0.id == record.id }) {
                guard existing.profiles == record.profiles && existing.teamID == record.teamID else {
                    throw EmberSlotError.message("A different recovery record already exists for \(record.id); nothing was overwritten.")
                }
            } else {
                current.append(record)
            }
        }
        try save(current)
        return current
    }
    static func save(_ records: [EmberInactiveSlot]) throws {
        let data = try JSONEncoder().encode(records)
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: location, options: [.atomic, .completeFileProtection])
    }
}

struct EmberRecoveryProfilesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var records: [EmberInactiveSlot]

    init(records: [EmberInactiveSlot]) { self.records = records }

    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents,
              bytes.count <= 5_000_000 else {
            throw EmberSlotError.message("Recovery archive is missing or too large.")
        }
        records = try JSONDecoder().decode([EmberInactiveSlot].self, from: bytes)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try JSONEncoder().encode(records))
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
    @Published private(set) var inactive: [EmberInactiveSlot] = []
    @Published private(set) var recoveryStoreError: String?
    @Published private(set) var backups: [String: EmberBackupSummary] = [:]
    @Published var isLoading = false
    @Published var status = "Connect LocalDevVPN and import this device's pairing file to scan installed apps."
    private let proxy = InstallationAppProxy()

    override init() {
        super.init()
        proxy.delegate = self
        do {
            inactive = try EmberSlotStore.load()
        } catch {
            recoveryStoreError = "Recovery records cannot be read. Do not deactivate, uninstall, or refresh apps until this is resolved: " + error.localizedDescription
        }
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

    func checkBackup(_ bundleID: String) async {
        let found = await Task.detached(priority: .utility) {
            EmberAppDataBackup.verifiedBackup(for: bundleID)
        }.value
        if let found { backups[bundleID] = found }
        else { backups.removeValue(forKey: bundleID) }
    }

    func backUp(_ app: AppInfo) async {
        guard !isLoading, let identifier = app.CFBundleIdentifier else { return }
        isLoading = true
        status = "Backing up \(app.displayName). Keep EmberSign open until verification finishes..."
        defer { isLoading = false }
        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                try EmberAppDataBackup.backup(bundleID: identifier)
            }.value
            backups[identifier] = summary
            status = "Verified \(summary.files.count) data files (\(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file))) for \(app.displayName). Shared app groups and keychain cannot be included."
        } catch {
            status = "Backup failed. App was not modified: " + error.localizedDescription
            EmberErrorCenter.shared.record(error, operation: "Back up app data")
        }
    }

    func restoreData(_ app: AppInfo) async {
        guard !isLoading, let identifier = app.CFBundleIdentifier else { return }
        isLoading = true
        status = "Restoring verified app data to \(app.displayName)..."
        defer { isLoading = false }
        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                try EmberAppDataBackup.restore(bundleID: identifier)
            }.value
            status = "Restored \(summary.files.count) files to \(app.displayName). Reopen the app to check its data."
        } catch {
            status = "Restore incomplete: " + error.localizedDescription
            EmberErrorCenter.shared.record(error, operation: "Restore app data")
        }
    }

    func uninstall(_ app: AppInfo, removePortalRecords: Bool) async {
        guard let bundleID = app.CFBundleIdentifier else { return }
        do {
            guard try !EmberSlotStore.hasSavedProfiles(for: bundleID) else {
                status = "Restore the app's saved provisioning profiles before uninstalling it. Otherwise its data may be lost."
                return
            }
        } catch {
            status = "Cannot verify recovery profiles. Uninstall cancelled: " + error.localizedDescription
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
        if recoveryStoreError != nil { return true }
        guard let bundleID else { return false }
        return inactive.contains(where: { $0.id == bundleID })
    }

    func exportRecovery() throws -> EmberRecoveryProfilesDocument {
        let records = try EmberSlotStore.load()
        guard !records.isEmpty else { throw EmberSlotError.message("No saved recovery profiles to export.") }
        return EmberRecoveryProfilesDocument(records: records)
    }

    func importRecovery(_ url: URL) {
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 5_000_000 else {
                throw EmberSlotError.message("Recovery archive exceeds the 5 MB limit.")
            }
            let imported = try JSONDecoder().decode([EmberInactiveSlot].self, from: bytes)
            inactive = try EmberSlotStore.importRecovery(imported)
            recoveryStoreError = nil
            status = "Imported and validated \(imported.count) recovery record(s). No installed apps were modified."
        } catch {
            recoveryStoreError = "Recovery import failed: " + error.localizedDescription
            EmberErrorCenter.shared.record(error, operation: "Import app recovery profiles")
        }
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
            // Reload from disk before modifying the device; never overwrite an
            // unreadable or newer set of protected recovery profiles.
            let current = try EmberSlotStore.load()
            guard !current.contains(where: { $0.id == bundleID }) else {
                throw EmberSlotError.message("This app already has saved recovery profiles. Restore those first.")
            }
            inactive = current
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
                status = "Deactivated \(app.displayName) by removing \(matching.count) on-device profile(s). Its app and data remain installed. This is the method used by SideStore, but verify that your next installation can use the freed active slot."
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
            let current = try EmberSlotStore.load()
            guard let saved = current.first(where: { $0.id == record.id }),
                  saved.teamID == record.teamID, saved.profiles == record.profiles else {
                throw EmberSlotError.message("Recovery record has changed. Reopen Installed apps to load the saved profile data.")
            }
            let decoded = try saved.profiles.map { try EmberIOSProvisionProfile.parse($0) }
            guard !decoded.isEmpty,
                  decoded.allSatisfy({ $0.team == saved.teamID &&
                      $0.applicationPattern == saved.teamID + "." + saved.id }) else {
                throw EmberSlotError.message("Saved profiles are missing or do not match this app. No device changes were made.")
            }
            try await Task.detached(priority: .userInitiated) {
                try EmberSlotBridge.restore(saved.profiles)
            }.value
            let installed = try await Task.detached(priority: .userInitiated) {
                try EmberSlotBridge.read()
            }.value
            let profileIDs = Set(installed.compactMap { try? EmberIOSProvisionProfile.parse($0).id })
            let required = Set(decoded.map(\.id))
            guard required.isSubset(of: profileIDs) else {
                throw EmberSlotError.message("Profile restoration was not verified. Keep the recovery record.")
            }
            let previous = current
            inactive = current
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
    @State private var pendingDataRestore: AppInfo?
    @State private var exportingRecovery = false
    @State private var importingRecovery = false
    @State private var recoveryDocument: EmberRecoveryProfilesDocument?

    var body: some View {
        List {
            scanSection
            if !model.inactive.isEmpty { recoverySection }
            installedSection
            disclaimerSection
        }
        .navigationTitle("Installed apps")
        .task { await model.scan() }
        .fileExporter(isPresented: $exportingRecovery, document: recoveryDocument,
                      contentType: .json, defaultFilename: "EmberSign-Recovery-Profiles") { result in
            if case .failure(let error) = result {
                model.status = "Recovery export failed: " + error.localizedDescription
            }
        }
        .fileImporter(isPresented: $importingRecovery, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): model.importRecovery(url)
            case .failure(let error): model.status = "Recovery import failed: " + error.localizedDescription
            }
        }
        .sheet(item: $selected) { app in appDetails(app) }
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
        .confirmationDialog("Deactivate \(pendingDeactivation?.displayName ?? "app")?", isPresented: Binding(
            get: { pendingDeactivation != nil },
            set: { if !$0 { pendingDeactivation = nil } }
        ), titleVisibility: .visible) {
            if let app = pendingDeactivation {
                Button("Deactivate and retain recovery profiles") {
                    pendingDeactivation = nil
                    Task { await model.deactivate(app) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDeactivation = nil }
        } message: {
            Text("Removes installed provisioning profiles while keeping the app and its data on this iPhone. It may free a Personal Team active-app slot. Reactivation requires restoring profiles; keep EmberSign and its data installed. This operation has not been device-tested in EmberSign.")
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
        .confirmationDialog("Overwrite backed-up files in \(pendingDataRestore?.displayName ?? "app")?", isPresented: Binding(
            get: { pendingDataRestore != nil },
            set: { if !$0 { pendingDataRestore = nil } }
        ), titleVisibility: .visible) {
            if let app = pendingDataRestore {
                Button("Restore verified snapshot") {
                    pendingDataRestore = nil
                    Task { await model.restoreData(app) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDataRestore = nil }
        } message: {
            Text("Close the target app before restoring. Restoration replaces files from the snapshot. This cannot recover app-group or keychain data. Keep the current app installed.")
        }
    }

    private var scanSection: some View {
        Section {
            Button { Task { await model.scan() } } label: {
                HStack { Label("Scan device", systemImage: "arrow.clockwise"); Spacer(); if model.isLoading { ProgressView() } }
            }.disabled(model.isLoading)
            Text(model.status).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
        } footer: {
            Text("The list comes from Apple's paired-device installation service. A working pairing tunnel is required.")
        }
    }

    private var recoverySection: some View {
        Section("Saved provisioning profiles / recovery") {
            Button {
                do {
                    recoveryDocument = try model.exportRecovery()
                    exportingRecovery = true
                } catch { model.status = error.localizedDescription }
            } label: { Label("Export recovery profiles to Files", systemImage: "square.and.arrow.up") }
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

    private var installedSection: some View {
        Section("Installed apps") {
            ForEach(model.apps) { app in installedRow(app) }
        }
    }

    private func installedRow(_ app: AppInfo) -> some View {
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
                    Label("Deactivate (on-device profiles)", systemImage: "pause.circle")
                }.tint(.orange)
            }
        }
    }

    private var disclaimerSection: some View {
        Section {
            if let warning = model.recoveryStoreError {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Button { importingRecovery = true } label: {
                Label("Import saved recovery profiles from Files", systemImage: "square.and.arrow.down")
            }
            Text("Deactivation saves and removes on-device signing profiles and leaves the app and its data installed, as in SideStore's deactivation operation. The app will stop opening until reactivated. Whether iOS releases an active free-team slot must be verified on your device. Purchased/enterprise certificate apps are excluded.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func appDetails(_ app: AppInfo) -> some View {
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
                if accounts.account(forTeamID: app.teamIdentifier) == nil {
                    Section("External certificate") {
                        Text("This app may have been installed with a purchased signing certificate, including one imported into FlareStore. EmberSign can inspect and back up accessible data, launch it, or remove it through pairing. Re-signing requires the matching .p12 private key, its password, and a valid provisioning profile. These cannot be recovered from the installed app alone.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let bundleID = app.CFBundleIdentifier, bundleID != Bundle.main.bundleIdentifier {
                    launchControls(bundleID)
                    Section {
                        if let saved = model.backups[bundleID] {
                            LabeledContent("Saved", value: saved.createdAt.formatted())
                            LabeledContent("Files", value: "\(saved.files.count)")
                            LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: saved.bytes, countStyle: .file))
                            Button {
                                selected = nil
                                pendingDataRestore = app
                            } label: { Label("Restore data from backup", systemImage: "arrow.uturn.backward") }
                        } else {
                            Text("No verified backup recorded").font(.caption).foregroundStyle(.secondary)
                        }
                        Button {
                            selected = nil
                            Task { await model.backUp(app) }
                        } label: { Label("Back up app data", systemImage: "externaldrive.badge.plus") }
                            .disabled(model.isLoading)
                    } header: {
                        Text("App data backup")
                    } footer: {
                        Text("Uses paired-device House Arrest access to Documents and Library where iOS permits it. Does not capture app groups, keychain, or files iOS blocks. Backup verification does not guarantee full data portability.")
                    }
                }
                if let bundleID = app.CFBundleIdentifier,
                   accounts.account(forTeamID: app.teamIdentifier) != nil,
                   !model.hasSavedProfiles(bundleID),
                   refresh.trackedApps().contains(where: { $0.id == bundleID }) {
                    Section {
                        Button {
                            selected = nil
                            Task { _ = await refresh.refresh(bundleID: bundleID) }
                        } label: { Label("Re-sign and reinstall this app", systemImage: "arrow.triangle.2.circlepath") }
                            .disabled(refresh.isRunning)
                    } header: {
                        Text("Refresh signing")
                    } footer: {
                        Text("Uses the Apple Account EmberSign linked to this app. Check its current signing identity before refreshing.")
                    }
                }
                if model.isFreeTeam(app.teamIdentifier) {
                    Section {
                        if model.hasSavedProfiles(app.CFBundleIdentifier) {
                            Text("This app has saved profiles. Restore them from the recovery section.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if app.CFBundleIdentifier != Bundle.main.bundleIdentifier {
                            Button {
                                pendingDeactivation = app
                                selected = nil
                            } label: { Label("Deactivate (on-device profiles)", systemImage: "pause.circle") }
                        }
                    } footer: {
                        Text("This removes installed provisioning profiles without uninstalling. Check your active-app slot availability after deactivation.")
                    }
                }
                if !model.hasSavedProfiles(app.CFBundleIdentifier) {
                    Section {
                        Button(role: .destructive) { pendingRemoval = app; selected = nil } label: { Label("Uninstall or revoke", systemImage: "trash") }
                    } footer: {
                        Text("Apple controls when a Personal Team App ID counts as reusable.")
                    }
                }
            }
            .navigationTitle(app.displayName)
            .task {
                if let identifier = app.CFBundleIdentifier { await model.checkBackup(identifier) }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { selected = nil } } }
        }
    }

    @ViewBuilder
    private func launchControls(_ bundleID: String) -> some View {
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
            Text("JIT preference applies only to launches through EmberSign. Home Screen launches are unaffected. Requires pairing and LocalDevVPN on iOS 17.4+.")
                .font(.footnote).foregroundStyle(.secondary)
            if !jit.status.isEmpty { Text(jit.status).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
