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

    // Directly read valid pairing records already copied into On My iPhone > EmberSign.
    // This avoids file-provider picker issues without removing the native picker.
    static func localPairingRecords() throws -> [URL] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = try FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        return files.filter { source in
            guard ["plist", "mobiledevicepairing"].contains(source.pathExtension.lowercased()),
                  let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 4 * 1024 * 1024,
                  let data = try? Data(contentsOf: source),
                  let record = try? EmberPairingRecord(data: data),
                  record.kind == .lockdown,
                  record.udid != nil else { return false }
            return true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

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

    static func remoteSocketAddress(_ overrideIP: String? = nil) throws -> sockaddr_in {
        let address = (overrideIP ?? remoteIP).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, address != "10.7.0.1" else {
            throw EmberError.message("Enter the iPhone 13's own Wi-Fi IPv4 address, not LocalDevVPN's 10.7.0.1 address.")
        }
        var sock = sockaddr_in()
        sock.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
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
            return try await verifyRemoteAddress(remoteIP)
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

    /// Native Lockdown calls can block indefinitely. Time out the UI without
    /// forcibly terminating the in-flight native operation.
    static func verifyRemoteAddress(_ ip: String, timeoutSeconds: Int = 9) async throws -> String {
        _ = try targetUDID()
        _ = try remoteSocketAddress(ip)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let gate = EmberRemoteProbeGate(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard EmberRemoteWiFiBridge.isTCPReachable(ip, timeoutMilliseconds: 1500) else {
                        throw EmberError.message("Cannot reach iPhone wireless sync at \(ip):62078. Check its Wi-Fi IP, wireless syncing, and network isolation.")
                    }
                    gate.finish(.success(try EmberRemoteWiFiBridge.probe(at: ip)))
                } catch {
                    gate.finish(.failure(error))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
                gate.finish(.failure(EmberError.message("The paired iPhone connection timed out after \(timeoutSeconds) seconds. Check its wireless-sync service and Wi-Fi connection.")))
            }
        }
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

    static func isTCPReachable(_ ip: String, timeoutMilliseconds: Int32) -> Bool {
        guard var address = try? EmberInstallTarget.remoteSocketAddress(ip) else { return false }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }
        let flags = Darwin.fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        let code = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if code == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var status = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard Darwin.poll(&status, 1, timeoutMilliseconds) > 0 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        return Darwin.getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 && socketError == 0
    }

    private static func failure(_ pointer: UnsafeMutablePointer<IdeviceFfiError>) -> Error {
        let code = pointer.pointee.code
        let message = pointer.pointee.message.map { String(cString: $0) } ?? "Unknown device error"
        idevice_error_free(pointer)
        return EmberError.message("iPhone 13 service error \(code): \(message)")
    }

    private static func withVerifiedProvider<T>(at ip: String? = nil, _ action: (OpaquePointer, String) throws -> T) throws -> T {
        let expected = try EmberInstallTarget.targetUDID()
        var address = try EmberInstallTarget.remoteSocketAddress(ip)
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

    static func probe(at ip: String) throws -> String {
        try withVerifiedProvider(at: ip) { _, udid in
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

/// Resume a timed-out native probe exactly once, even if the socket later returns.
private final class EmberRemoteProbeGate {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<String, Error>

    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }

    func finish(_ outcome: Result<String, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        continuation.resume(with: outcome)
    }
}

/// Find Apple wireless-sync services on the current LAN. Never select a
/// discovered host until its Lockdown UDID matches the imported pairing file.
private final class EmberRemoteDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var isSearching = false
    @Published private(set) var status = ""
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var attempted = Set<String>()
    private var generation = 0
    private var onMatch: ((String) -> Void)?

    func start(onMatch: @escaping (String) -> Void) {
        stop()
        let ticket = generation
        attempted.removeAll()
        self.onMatch = onMatch
        isSearching = true
        status = "Finding iPhones advertising Apple wireless sync on this network…"
        let search = NetServiceBrowser()
        browser = search
        search.delegate = self
        search.searchForServices(ofType: "_apple-mobdev2._tcp.", inDomain: "local.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.generation == ticket, self.isSearching else { return }
            self.status = self.attempted.isEmpty
                ? "No wireless-sync iPhones found. Check Local Network permission, wireless sync and Wi-Fi isolation, or enter the IP manually."
                : "Found Apple devices, but none verified against the saved iPhone 13 pairing record."
            self.stopBrowsing()
        }
    }

    func stop() {
        generation += 1
        stopBrowsing()
        onMatch = nil
    }

    private func stopBrowsing() {
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        for service in services {
            service.stop()
            service.delegate = nil
        }
        services.removeAll()
        isSearching = false
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        status = "Discovery could not start. Check Settings > EmberSign > Local Network, or enter the IP manually."
        stopBrowsing()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        for data in sender.addresses ?? [] {
            guard let ip = Self.ipv4(from: data), attempted.insert(ip).inserted else { continue }
            let ticket = generation
            status = "Checking trusted pairing at \(ip)…"
            Task {
                do {
                    let verification = try await EmberInstallTarget.verifyRemoteAddress(ip, timeoutSeconds: 7)
                    await MainActor.run {
                        guard self.generation == ticket, self.isSearching else { return }
                        self.onMatch?(ip)
                        self.status = "Detected \(ip). \(verification)"
                        self.stopBrowsing()
                    }
                } catch {
                    await MainActor.run {
                        guard self.generation == ticket, self.isSearching else { return }
                        self.status = "Device at \(ip) did not verify; searching for your paired iPhone…"
                    }
                }
            }
        }
    }

    private static func ipv4(from data: Data) -> String? {
        guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
        var address = sockaddr_in()
        _ = withUnsafeMutableBytes(of: &address) { data.copyBytes(to: $0) }
        guard address.sin_family == sa_family_t(AF_INET) else { return nil }
        var ipAddress = address.sin_addr
        var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ipAddress, &output, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: output)
    }
}

struct EmberInstallTargetView: View {
    @AppStorage(EmberInstallTarget.modeKey) private var mode = "self"
    @AppStorage(EmberInstallTarget.hostKey) private var host = ""
    @State private var importing = false
    @State private var localPairingOptions: [URL] = []
    @State private var showingLocalPairingOptions = false
    @State private var busy = false
    @State private var result = ""
    @State private var importedUDID: String?
    @StateObject private var discovery = EmberRemoteDiscovery()

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
                    TextField("iPhone 13 Wi-Fi IPv4 address (manual fallback)", text: $host)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        startDiscovery()
                    } label: {
                        HStack {
                            Label("Auto-detect paired iPhone", systemImage: "wifi")
                            Spacer()
                            if discovery.isSearching { ProgressView() }
                        }
                    }
                    .disabled(importedUDID == nil || discovery.isSearching)
                    if !discovery.status.isEmpty {
                        Text(discovery.status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Button("Import iPhone 13 pairing record") { importing = true }
                    Button("Import from EmberSign folder (no picker)") { chooseLocalPairing() }
                    Text("For direct import, save the .plist or .mobiledevicepairing file in Files > On My iPhone > EmberSign.")
                        .font(.footnote).foregroundStyle(.secondary)
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
                    discovery.stop()
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
                result = "iPhone 13 pairing imported. Looking for it on local Wi-Fi…"
                startDiscovery()
            } catch { result = error.localizedDescription }
        }
        .confirmationDialog("Select a pairing file in EmberSign", isPresented: $showingLocalPairingOptions,
                            titleVisibility: .visible) {
            ForEach(localPairingOptions, id: \.absoluteString) { file in
                Button(file.lastPathComponent) { importLocalPairing(file) }
            }
        }
        .onAppear {
            // Opening this screen opts into the paired-device installer.
            // The web fallback remains available in Settings > Installation.
            UserDefaults.standard.set(1, forKey: "Feather.installationMethod")
            importedUDID = (try? EmberPairingRecord(data: Data(contentsOf: EmberInstallTarget.remoteRecordURL)))?.udid
            if mode == "remote" && importedUDID != nil { startDiscovery() }
        }
        .onChange(of: mode) { newMode in
            if newMode == "remote" && importedUDID != nil {
                startDiscovery()
            } else {
                discovery.stop()
            }
        }
        .onDisappear { discovery.stop() }
    }

    private func startDiscovery() {
        guard mode == "remote" else { return }
        guard importedUDID != nil else {
            result = "Import the iPhone 13 Lockdown pairing record before auto-detection."
            return
        }
        discovery.start { address in
            host = address
            result = "Paired iPhone 13 found at \(address). You can now install over local Wi-Fi."
        }
    }

    private func chooseLocalPairing() {
        do {
            let options = try EmberInstallTarget.localPairingRecords()
            guard !options.isEmpty else {
                result = "No valid iPhone Lockdown pairing file in On My iPhone > EmberSign. Copy your iPhone 13 pairing .plist here using Files."
                return
            }
            if options.count == 1 {
                importLocalPairing(options[0])
            } else {
                localPairingOptions = options
                showingLocalPairingOptions = true
            }
        } catch { result = error.localizedDescription }
    }

    private func importLocalPairing(_ source: URL) {
        do {
            try EmberInstallTarget.importRemotePairing(source)
            importedUDID = try EmberInstallTarget.targetUDID()
            result = "iPhone 13 pairing imported from EmberSign folder. Looking for it on Wi-Fi…"
            startDiscovery()
        } catch { result = error.localizedDescription }
    }
}
