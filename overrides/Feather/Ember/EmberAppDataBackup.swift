import Foundation
import CryptoKit
import IDevice
import IDeviceSwift
import Darwin

/// A device-side data snapshot. It deliberately avoids claiming to capture an
/// app's keychain, shared app groups, or data that iOS refuses to expose.
struct EmberBackupSummary: Codable {
    struct File: Codable {
        let path: String
        let byteCount: Int64
        let sha256: String
    }

    let bundleID: String
    let createdAt: Date
    let files: [File]

    var bytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }
}

private enum EmberBackupFailure: LocalizedError {
    case message(String)

    static func fromFFI(_ pointer: UnsafeMutablePointer<IdeviceFfiError>) -> Self {
        let message = pointer.pointee.message.map { String(cString: $0) } ?? "Unknown device error"
        idevice_error_free(pointer)
        return .message(message)
    }

    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return "Cannot back up this app."
    }
}

/// Backups are stored in EmberSign's protected Application Support directory.
/// An incomplete backup never replaces a previously verified snapshot.
enum EmberAppDataBackup {
    private static let roots = ["Documents", "Library"]
    private static let manifestName = "manifest.json"
    private static let maximumEntryCount = 100_000

    private static func directory(for bundleID: String) -> URL {
        let identifier = SHA256.hash(data: Data(bundleID.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EmberSign-AppBackups", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
    }

    static func verifiedBackup(for bundleID: String) -> EmberBackupSummary? {
        let directory = directory(for: bundleID)
        let manifestURL = directory.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(EmberBackupSummary.self, from: data),
              manifest.bundleID == bundleID,
              !manifest.files.isEmpty else { return nil }
        for file in manifest.files {
            guard safeRelativePath(file.path) else { return nil }
            let location = directory.appendingPathComponent(file.path)
            guard let bytes = try? Data(contentsOf: location, options: .mappedIfSafe),
                  Int64(bytes.count) == file.byteCount,
                  digest(bytes) == file.sha256 else { return nil }
        }
        return manifest
    }

    static func backup(bundleID: String) throws -> EmberBackupSummary {
        let final = directory(for: bundleID)
        let parent = final.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent("pending-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let files = try withAFC(for: bundleID) { client in
            var files: [EmberBackupSummary.File] = []
            for root in roots {
                // Some apps omit Documents, while others omit Library. At least
                // one accessible root must exist to consider a backup valid.
                guard (try? itemInfo(client, root)) != nil else { continue }
                try copyFromDevice(client, at: root, to: temporary, entries: &files)
            }
            return files
        }
        guard !files.isEmpty else {
            throw EmberBackupFailure.message("No readable app data was returned by House Arrest. Nothing was deactivated. This app may not allow paired-device access.")
        }
        let manifest = EmberBackupSummary(bundleID: bundleID, createdAt: Date(), files: files)
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: temporary.appendingPathComponent(manifestName), options: .atomic)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)

        // Verify the exact temporary files before replacing the last good backup.
        try verify(manifest, in: temporary)
        if FileManager.default.fileExists(atPath: final.path) {
            _ = try FileManager.default.replaceItemAt(final, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: final)
        }
        guard verifiedBackup(for: bundleID) != nil else {
            throw EmberBackupFailure.message("Backup verification failed after committing. Do not uninstall or deactivate this app.")
        }
        return manifest
    }

    /// Restore is non-destructive: it overwrites only backed-up files and does
    /// not remove any other files the reinstalled app may have created.
    static func restore(bundleID: String) throws -> EmberBackupSummary {
        guard let manifest = verifiedBackup(for: bundleID) else {
            throw EmberBackupFailure.message("No intact verified backup exists for this app.")
        }
        let directory = directory(for: bundleID)
        try withAFC(for: bundleID) { client in
            for file in manifest.files {
                let components = file.path.split(separator: "/").map(String.init)
                var parent = ""
                for component in components.dropLast() {
                    parent = parent.isEmpty ? component : parent + "/" + component
                    if (try? itemInfo(client, parent)) == nil {
                        if let error = afc_make_directory(client, parent) {
                            throw EmberBackupFailure.fromFFI(error)
                        }
                    }
                }
                let local = directory.appendingPathComponent(file.path)
                let data = try Data(contentsOf: local, options: .mappedIfSafe)
                guard digest(data) == file.sha256 else {
                    throw EmberBackupFailure.message("Local backup changed while restoring: \(file.path)")
                }
                var handle: OpaquePointer?
                if let error = afc_file_open(client, file.path, .AfcWrOnly, &handle) {
                    throw EmberBackupFailure.fromFFI(error)
                }
                guard let handle else { throw EmberBackupFailure.message("Cannot open \(file.path) for restore.") }
                defer { if let error = afc_file_close(handle) { idevice_error_free(error) } }
                for offset in stride(from: 0, to: data.count, by: 128 * 1024) {
                    let end = min(offset + 128 * 1024, data.count)
                    let chunk = data.subdata(in: offset..<end)
                    if let error = chunk.withUnsafeBytes({ raw in
                        afc_file_write(handle, raw.bindMemory(to: UInt8.self).baseAddress, chunk.count)
                    }) {
                        throw EmberBackupFailure.fromFFI(error)
                    }
                }
            }
        }
        return manifest
    }

    private static func verify(_ manifest: EmberBackupSummary, in directory: URL) throws {
        for file in manifest.files {
            guard safeRelativePath(file.path) else { throw EmberBackupFailure.message("Unsafe backup path") }
            let bytes = try Data(contentsOf: directory.appendingPathComponent(file.path), options: .mappedIfSafe)
            guard Int64(bytes.count) == file.byteCount, digest(bytes) == file.sha256 else {
                throw EmberBackupFailure.message("Backup file failed hash validation: \(file.path)")
            }
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func safeRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.hasPrefix("/") && !components.isEmpty &&
            components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func itemInfo(_ client: OpaquePointer, _ path: String) throws -> (isDirectory: Bool, isLink: Bool, bytes: Int64) {
        var info = AfcFileInfo()
        if let error = afc_get_file_info(client, path, &info) { throw EmberBackupFailure.fromFFI(error) }
        defer { afc_file_info_free(&info) }
        let type = info.st_ifmt.map { String(cString: $0) } ?? ""
        return (type == "S_IFDIR", type == "S_IFLNK", Int64(info.size))
    }

    private static func list(_ client: OpaquePointer, _ path: String) throws -> [String] {
        var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        var count = 0
        if let error = afc_list_directory(client, path, &entries, &count) { throw EmberBackupFailure.fromFFI(error) }
        guard count >= 0, count <= maximumEntryCount, let entries else {
            throw EmberBackupFailure.message("Unreasonable or empty directory response from device")
        }
        // IDevice FFI v0.1.57 specifies caller ownership for this list and its strings.
        defer {
            for index in 0..<count { free(entries[index]) }
            free(entries)
        }
        return (0..<count).compactMap { index in
            entries[index].map { String(cString: $0) }
        }.filter { $0 != "." && $0 != ".." }
    }

    private static func copyFromDevice(_ client: OpaquePointer, at path: String, to root: URL,
                                       entries: inout [EmberBackupSummary.File]) throws {
        let info = try itemInfo(client, path)
        if info.isLink { return } // No traversal outside the app's real data directories.
        guard safeRelativePath(path) else { throw EmberBackupFailure.message("Invalid device path") }
        let local = root.appendingPathComponent(path)
        if info.isDirectory {
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            for name in try list(client, path) {
                guard name != ".", name != "..", !name.contains("/") else { continue }
                guard entries.count < maximumEntryCount else { throw EmberBackupFailure.message("Too many backup files") }
                try copyFromDevice(client, at: path + "/" + name, to: root, entries: &entries)
            }
            return
        }
        var handle: OpaquePointer?
        if let error = afc_file_open(client, path, .AfcRdOnly, &handle) { throw EmberBackupFailure.fromFFI(error) }
        guard let handle else { throw EmberBackupFailure.message("Cannot read \(path)") }
        defer { if let error = afc_file_close(handle) { idevice_error_free(error) } }
        FileManager.default.createFile(atPath: local.path, contents: nil)
        let file = try FileHandle(forWritingTo: local)
        defer { try? file.close() }
        var hash = SHA256()
        var total: Int64 = 0
        while true {
            var bytes: UnsafeMutablePointer<UInt8>?
            var length = 0
            if let error = afc_file_read(handle, &bytes, 128 * 1024, &length) {
                throw EmberBackupFailure.fromFFI(error)
            }
            guard length > 0 else { break }
            guard let bytes else { throw EmberBackupFailure.message("Device returned missing file bytes") }
            let chunk = Data(bytes: bytes, count: length)
            afc_file_read_data_free(bytes, length)
            hash.update(data: chunk)
            total += Int64(length)
            try file.write(contentsOf: chunk)
        }
        guard total == info.bytes else {
            throw EmberBackupFailure.message("File changed during backup: \(path)")
        }
        entries.append(.init(path: path, byteCount: total,
                             sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()))
    }

    private static func withAFC<T>(for bundleID: String, _ operation: (OpaquePointer) throws -> T) throws -> T {
        let pairingPath = HeartbeatManager.pairingFile()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw EmberBackupFailure.message("Import this device's pairing file first.")
        }
        var house: OpaquePointer?
        if #available(iOS 17.4, *) {
            var pairing: OpaquePointer?
            if let error = rp_pairing_file_read(pairingPath, &pairing) { throw EmberBackupFailure.fromFFI(error) }
            guard let pairing else { throw EmberBackupFailure.message("Invalid remote pairing file") }
            defer { rp_pairing_file_free(pairing) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            let configuredPort = UserDefaults.standard.integer(forKey: "EmberSign.jit.endpoint.port")
            let port = configuredPort == 0 ? 49152 : configuredPort
            guard (1...65535).contains(port) else { throw EmberBackupFailure.message("Invalid device tunnel port") }
            addr.sin_port = CFSwapInt16HostToBig(UInt16(port))
            let host = UserDefaults.standard.string(forKey: "EmberSign.jit.endpoint.deviceIP") ?? "10.7.0.1"
            guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { throw EmberBackupFailure.message("Invalid device IP") }
            var adapter: OpaquePointer?
            var handshake: OpaquePointer?
            let error = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: idevice_sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                                            "EmberSign", pairing, nil, nil, &adapter, &handshake)
                }
            }
            if let error { throw EmberBackupFailure.fromFFI(error) }
            guard let adapter, let handshake else { throw EmberBackupFailure.message("Remote tunnel unavailable") }
            defer { rsd_handshake_free(handshake); adapter_free(adapter) }
            if let error = house_arrest_client_connect_rsd(adapter, handshake, &house) {
                throw EmberBackupFailure.fromFFI(error)
            }
            return try vendAndOperate(&house, bundleID: bundleID, operation)
        } else {
            let heartbeat = HeartbeatManager.shared
            guard heartbeat.checkSocketConnection().isConnected else {
                throw EmberBackupFailure.message("Connect LocalDevVPN first")
            }
            var pairing: OpaquePointer?
            if let error = idevice_pairing_file_read(pairingPath, &pairing) { throw EmberBackupFailure.fromFFI(error) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = CFSwapInt16HostToBig(heartbeat.port)
            guard inet_pton(AF_INET, heartbeat.ipAddress, &addr.sin_addr) == 1 else {
                idevice_pairing_file_free(pairing)
                throw EmberBackupFailure.message("Invalid device IP")
            }
            var provider: OpaquePointer?
            let error = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    idevice_tcp_provider_new($0, pairing, "EmberSign", &provider)
                }
            }
            if let error {
                idevice_pairing_file_free(pairing)
                throw EmberBackupFailure.fromFFI(error)
            }
            guard let provider else { throw EmberBackupFailure.message("Device provider unavailable") }
            defer { idevice_provider_free(provider) }
            if let error = house_arrest_client_connect(provider, &house) {
                throw EmberBackupFailure.fromFFI(error)
            }
            return try vendAndOperate(&house, bundleID: bundleID, operation)
        }
    }

    private static func vendAndOperate<T>(_ house: inout OpaquePointer?, bundleID: String,
                                          _ operation: (OpaquePointer) throws -> T) throws -> T {
        guard let house else { throw EmberBackupFailure.message("House Arrest unavailable") }
        var afc: OpaquePointer?
        // This FFI consumes the House Arrest handle whether vending succeeds or fails.
        if let error = house_arrest_vend_container(house, bundleID, &afc) {
            throw EmberBackupFailure.fromFFI(error)
        }
        guard let afc else { throw EmberBackupFailure.message("iOS denied access to this app's data") }
        defer { afc_client_free(afc) }
        return try operation(afc)
    }
}
