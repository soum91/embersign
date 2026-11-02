import Foundation
import SwiftUI
import UniformTypeIdentifiers
import IDevice
import IDeviceSwift
import ZIPFoundation
import Darwin

/// SideStore-style installs target the iPhone running EmberSign through LocalDevVPN.
/// Remote Wi-Fi installs instead require a separate trusted Lockdown pairing record
/// for the destination iPhone and a reachable wireless-sync service on port 62078.
enum EmberInstallTarget {
    static let modeKey = "EmberSign.installTarget.mode"
    static let hostKey = "EmberSign.installTarget.remoteIPv4"
    private static let remoteRecordName = "EmberSign-Remote-iPhone.plist"

    static var isRemote: Bool { UserDefaults.standard.string(forKey: modeKey) == "remote" }
    static var remoteIP: String { UserDefaults.standard.string(forKey: hostKey) ?? "" }
    static var remoteRecordURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(remoteRecordName)
    }

    static func pairingRecord() throws -> EmberPairingRecord {
        if isRemote {
            return try EmberPairingRecord(data: Data(contentsOf: remoteRecordURL))
        }
        return try EmberPairingStore.read()
    }

    static func targetUDID() throws -> String {
        let record = try pairingRecord()
        guard let udid = record.udid, !udid.isEmpty else {
            throw EmberError.message("The selected iPhone's pairing file has no UDID. Export a fresh device-specific pairing file using iLoader.")
        }
        if isRemote && record.kind != .lockdown {
            throw EmberError.message("Remote Wi-Fi installation to iOS 16 needs the iPhone 13's Lockdown pairing file, not a remote-pairing file.")
        }
        return udid
    }

    static var targetName: String { isRemote ? "Remote iPhone (Wi-Fi)" : UIDevice.current.name }

    static func importRemotePairing(_ source: URL) throws {
        let data = try EmberPairingStore.readImportedData(source)
        let record = try EmberPairingRecord(data: data)
        guard record.kind == .lockdown, let udid = record.udid, !udid.isEmpty else {
            throw EmberError.message("Import a Lockdown pairing file with the iPhone 13's UDID. Remote-pairing files are not supported for this Wi-Fi target.")
        }
        let destination = remoteRecordURL
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        var mutable = destination
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }

    static func remoteSocketAddress() throws -> sockaddr_in {
        let address = remoteIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, address != "10.7.0.1" else {
            throw EmberError.message("Enter the iPhone 13's own Wi-Fi IPv4 address, not LocalDevVPN's 10.7.0.1 address.")
        }
        var sock = sockaddr_in()
        sock.sin_family = sa_family_t(AF_INET)
        sock.sin_port = CFSwapInt16HostToBig(62078)
        guard inet_pton(AF_INET, address, &sock.sin_addr) == 1 else {
            throw EmberError.message("Enter an IPv4 address from the iPhone 13's Wi-Fi settings.")
        }
        let value = UInt32(bigEndian: sock.sin_addr.s_addr)
        let a = value >> 24, b = (value >> 16) & 0xff
        let local = a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
        guard local else {
            throw EmberError.message("Remote pairing is restricted to private local Wi-Fi addresses. Put both iPhones on the same trusted network.")
        }
        return sock
    }

    static func checkConnection() async throws -> String {
        if isRemote {
            return try await Task.detached(priority: .userInitiated) {
                try EmberRemoteWiFiBridge.probe()
            }.value
        }
        let record = try EmberPairingStore.read()
        if #available(iOS 17.4, *) {
            guard record.kind == .remote else {
                throw EmberError.message("This iOS version requires a remote-pairing record for on-device installation.")
            }
            return "Remote-pairing record available. Connect LocalDevVPN and install to verify the RSD tunnel."
        }
        guard record.kind == .lockdown else {
            throw EmberError.message("iOS 16 requires a Lockdown pairing file from this iPhone.")
        }
        guard HeartbeatManager.shared.checkSocketConnection(timeoutInSeconds: 4).isConnected else {
            throw EmberError.message("LocalDevVPN is not reachable. Start LocalDevVPN on this iPhone and keep Wi-Fi enabled.")
        }
        return "LocalDevVPN tunnel is reachable on this iPhone. Pairing trust is confirmed when the installer connects."
    }

    static func install(at ipa: URL, viewModel: InstallerStatusViewModel) async throws {
        if isRemote {
            try await EmberRemoteWiFiBridge.install(ipa: ipa, viewModel: viewModel)
        } else {
            _ = try await checkConnection()
            let installer = InstallationProxy(viewModel: viewModel)
            try await installer.install(at: ipa)
        }
    }
}

/// This is deliberately separate from HeartbeatManager: its provider always points
/// to LocalDevVPN on the *running* phone, not to another iPhone on Wi-Fi.
private enum EmberRemoteWiFiBridge {
    private static func verifySignedProfiles(ipa: URL, udid: String) throws {
        let archive = try Archive(url: ipa, accessMode: .read)
        var inspected = 0
        for entry in archive where entry.path.hasPrefix("Payload/") && entry.path.hasSuffix("/embedded.mobileprovision") {
            guard entry.uncompressedSize < 1_048_576 else {
                throw EmberError.message("An embedded signing profile is unexpectedly large. Installation stopped.")
            }
            var content = Data()
            _ = try archive.extract(entry) { content.append($0) }
            let profile = try EmberIOSProvisionProfile.parse(content)
            guard !profile.isExpired else {
                throw EmberError.message("Provisioning profile \(profile.name) has expired. Re-sign before installing.")
            }
            if !profile.provisionsAllDevices &&
               !profile.provisionedDevices.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }) {
                throw EmberError.message("The IPA's signing profile \(profile.name) does not authorize the iPhone 13 UDID. Provision/sign for the selected destination before installing.")
            }
            inspected += 1
        }
        guard inspected > 0 else {
            throw EmberError.message("No embedded provisioning profile found. Sign the IPA for the selected iPhone before installing.")
        }
    }

    private static func failure(_ pointer: UnsafeMutablePointer<IdeviceFfiError>) -> Error {
        let code = pointer.pointee.code
        let message = pointer.pointee.message.map { String(cString: $0) } ?? "Unknown device error"
        idevice_error_free(pointer)
        return EmberError.message("iPhone 13 service error \(code): \(message)")
    }

    private static func withVerifiedProvider<T>(_ action: (OpaquePointer, String) throws -> T) throws -> T {
        let expected = try EmberInstallTarget.targetUDID()
        var address = try EmberInstallTarget.remoteSocketAddress()
        var record: OpaquePointer?
        if let error = idevice_pairing_file_read(EmberInstallTarget.remoteRecordURL.path, &record) {
            throw failure(error)
        }
        guard let record else { throw EmberError.message("Could not read the remote pairing file.") }
        var provider: OpaquePointer?
        let connectionError = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                idevice_tcp_provider_new($0, record, "EmberSign Remote", &provider)
            }
        }
        if let connectionError { throw failure(connectionError) }
        guard let provider else { throw EmberError.message("Could not establish a trusted remote Wi-Fi device connection.") }
        defer { idevice_provider_free(provider) }

        var lockdown: OpaquePointer?
        if let error = lockdownd_connect(provider, &lockdown) { throw failure(error) }
        guard let lockdown else { throw EmberError.message("iPhone 13 Lockdown service unavailable.") }
        defer { lockdownd_client_free(lockdown) }
        var plist: UnsafeMutableRawPointer?
        if let error = lockdownd_get_value(lockdown, "UniqueDeviceID", nil, &plist) { throw failure(error) }
        guard let plist else { throw EmberError.message("Target device did not return its UDID.") }
        defer { plist_free(plist) }
        var value: UnsafeMutablePointer<CChar>?
        plist_get_string_val(plist, &value)
        defer { if let value { plist_mem_free(value) } }
        guard let value else { throw EmberError.message("Target returned an invalid UDID.") }
        let actual = String(cString: value)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw EmberError.message("Device mismatch. Pairing file expects \(expected), but Wi-Fi endpoint is \(actual). No app was installed.")
        }
        return try action(provider, actual)
    }

    static func probe() throws -> String {
        try withVerifiedProvider { _, udid in
            "Verified iPhone on Wi-Fi, UDID ending \(udid.suffix(6)). Remote installation is available."
        }
    }

    static func install(ipa: URL, viewModel: InstallerStatusViewModel) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: ipa.path) else {
                throw EmberError.message("Signed IPA not found. Sign the app again.")
            }
            try verifySignedProfiles(ipa: ipa, udid: EmberInstallTarget.targetUDID())
            try withVerifiedProvider { provider, _ in
                var afc: OpaquePointer?
                if let error = afc_client_connect(provider, &afc) { throw failure(error) }
                guard let afc else { throw EmberError.message("Cannot connect to the iPhone 13 file-staging service.") }
                defer { afc_client_free(afc) }
                _ = afc_make_directory(afc, "PublicStaging")
                let remotePath = "/PublicStaging/\(UUID().uuidString).ipa"
                defer { _ = afc_remove_path(afc, remotePath) }

                var handle: OpaquePointer?
                if let error = afc_file_open(afc, remotePath, AfcWrOnly, &handle) { throw failure(error) }
                guard let handle else { throw EmberError.message("Cannot stage the IPA on the iPhone 13.") }
                let source = try FileHandle(forReadingFrom: ipa)
                defer { try? source.close() }
                let total = max(1, (try? source.seekToEnd()) ?? 1)
                try source.seek(toOffset: 0)
                var sent: UInt64 = 0
                awaitStatus(viewModel, .sendingPayload)
                while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
                    let writeError = chunk.withUnsafeBytes { raw -> UnsafeMutablePointer<IdeviceFfiError>? in
                        afc_file_write(handle, raw.bindMemory(to: UInt8.self).baseAddress, chunk.count)
                    }
                    if let writeError {
                        _ = afc_file_close(handle)
                        throw failure(writeError)
                    }
                    sent += UInt64(chunk.count)
                    let progress = Double(sent) / Double(total)
                    Task { @MainActor in viewModel.uploadProgress = progress }
                }
                if let error = afc_file_close(handle) { throw failure(error) }

                var proxy: OpaquePointer?
                if let error = installation_proxy_connect(provider, &proxy) { throw failure(error) }
                guard let proxy else { throw EmberError.message("iPhone 13 installation service is unavailable.") }
                defer { installation_proxy_client_free(proxy) }
                awaitStatus(viewModel, .installing)
                let callback: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void = { progress, context in
                    guard let context else { return }
                    let model = Unmanaged<InstallerStatusViewModel>.fromOpaque(context).takeUnretainedValue()
                    Task { @MainActor in model.installProgress = min(1, Double(progress) / 100) }
                }
                let retained = Unmanaged.passRetained(viewModel)
                defer { retained.release() }
                let installError = remotePath.withCString { path in
                    installation_proxy_install_with_callback(proxy, path, nil, callback, retained.toOpaque())
                }
                if let installError { throw failure(installError) }
            }
            await MainActor.run { viewModel.status = .completed(.success(())) }
        }.value
    }

    private static func awaitStatus(_ model: InstallerStatusViewModel, _ status: InstallerStatusViewModel.InstallerStatus) {
        Task { @MainActor in model.status = status }
    }
}

struct EmberInstallTargetView: View {
    @AppStorage(EmberInstallTarget.modeKey) private var mode = "self"
    @AppStorage(EmberInstallTarget.hostKey) private var host = ""
    @State private var importing = false
    @State private var busy = false
    @State private var result = ""
    @State private var importedUDID: String?

    var body: some View {
        Form {
            Section("Installation destination") {
                Picker("Install to", selection: $mode) {
                    Text("This iPhone (SideStore method)").tag("self")
                    Text("iPhone 13 Pro Max over Wi-Fi").tag("remote")
                }
                .pickerStyle(.inline)
                Text(mode == "self"
                     ? "Sign and install on the iPhone running EmberSign using its pairing record and LocalDevVPN. This is the same-device approach used by SideStore."
                     : "Sign on this iPhone, then install to your iPhone 13 Pro Max over trusted Wi-Fi pairing. Both devices must be on the same LAN; wireless device sync must be enabled for the iPhone 13.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if mode == "remote" {
                Section("iPhone 13 Pro Max") {
                    TextField("iPhone 13 Wi-Fi IPv4 address", text: $host)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Import iPhone 13 pairing record") { importing = true }
                    if let importedUDID { LabeledContent("Paired UDID", value: "…\(importedUDID.suffix(8))") }
                    Text("Export a Lockdown pairing file for your iPhone 13 using iLoader. Keep its Wi-Fi syncing enabled and the phone awake while installing. Do not import the iPhone 17's pairing file here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section("This iPhone") {
                    Label(UIDevice.current.name, systemImage: "iphone.gen3")
                    Text("iOS \(UIDevice.current.systemVersion). For iOS 16, import this iPhone's Lockdown pairing file under Tools > Pairing file, then connect LocalDevVPN.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Connection") {
                Button {
                    busy = true
                    Task {
                        do { result = try await EmberInstallTarget.checkConnection() }
                        catch { result = error.localizedDescription }
                        busy = false
                    }
                } label: {
                    HStack { Label("Verify selected iPhone", systemImage: "checkmark.shield")
                        Spacer(); if busy { ProgressView() } }
                }.disabled(busy)
                if !result.isEmpty { Text(result).font(.footnote).textSelection(.enabled) }
                Text("A mismatched remote UDID blocks installation. Keep your pairing records private; they are device-trust credentials.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Install destination")
        .fileImporter(isPresented: $importing,
                      // Device pairing files may have a custom .mobiledevicepairing extension.
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { outcome in
            do {
                guard let file = try outcome.get().first else { return }
                try EmberInstallTarget.importRemotePairing(file)
                importedUDID = try EmberInstallTarget.targetUDID()
                result = "iPhone 13 pairing imported. Verify the Wi-Fi connection before installing."
            } catch { result = error.localizedDescription }
        }
        .onAppear {
            // Opening this screen opts into the paired-device installer.
            // The web fallback remains available in Settings > Installation.
            UserDefaults.standard.set(1, forKey: "Feather.installationMethod")
            importedUDID = (try? EmberPairingRecord(data: Data(contentsOf: EmberInstallTarget.remoteRecordURL)))?.udid
        }
    }
}
