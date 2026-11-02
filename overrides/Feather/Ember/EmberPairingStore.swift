import Foundation
import SwiftUI
import UniformTypeIdentifiers
import IDeviceSwift

enum EmberPairingStore {
    static var url: URL { URL(fileURLWithPath: HeartbeatManager.pairingFile()) }

    static func read() throws -> EmberPairingRecord {
        try EmberPairingRecord(data: Data(contentsOf: url))
    }

    static func importFile(_ source: URL) throws {
        try save(readImportedData(source))
    }

    static func readImportedData(_ source: URL) throws -> Data {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        // Coordinate the read so iCloud Drive and other file providers can materialize
        // a security-scoped file before its bytes are inspected and stored.
        let limit = 4 * 1024 * 1024
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var readError: Error?
        var importedData: Data?
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
            do {
                let size = try readableURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= limit else { throw EmberError.message("The pairing file is too large.") }
                let contents = try Data(contentsOf: readableURL)
                guard contents.count <= limit else { throw EmberError.message("The pairing file is too large.") }
                importedData = contents
            } catch {
                readError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let readError { throw readError }
        guard let importedData else {
            throw EmberError.message("The selected pairing file could not be read. Save it locally in Files and try again.")
        }
        return importedData
    }

    static func saveGeneratedRemote(_ data: Data) throws {
        let record = try EmberPairingRecord(data: data)
        guard record.kind == .remote else {
            throw EmberError.message("The on-device pairing service did not return a remote-pairing record.")
        }
        try save(data)
    }

    private static func save(_ data: Data) throws {
        let record = try EmberPairingRecord(data: data)
        // Validate first, then replace atomically. A bad import cannot erase a working record.
        try record.data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
        HeartbeatManager.shared.start(true)
        NotificationCenter.default.post(name: .emberPairingChanged, object: nil)
    }

    static func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        NotificationCenter.default.post(name: .emberPairingChanged, object: nil)
    }
}

extension Notification.Name {
    static let emberPairingChanged = Notification.Name("EmberSign.pairingChanged")
}

struct EmberPairingDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .propertyList] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
