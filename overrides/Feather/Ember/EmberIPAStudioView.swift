import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation

/// Local-only IPA preparation. No app archive or credentials are uploaded.
struct EmberIPAStudioOverview: Sendable {
    let name: String
    let identifier: String
    let version: String
    let build: String
    let minimumIOS: String
    let urlSchemes: String
    let hasWatch: Bool
    let nestedIDs: [String]
}

private enum EmberIPAStudioArchive {
    private static let maxEntry: UInt64 = 512 * 1024 * 1024
    private static let maxTotal: UInt64 = 3 * 1024 * 1024 * 1024

    static func takeCopy(_ source: URL) throws -> URL {
        guard ["ipa", "tipa"].contains(source.pathExtension.lowercased()) else {
            throw EmberIPAIdentityError.invalid("Choose an IPA or TIPA file.")
        }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("EmberIPAInput-" + UUID().uuidString + ".ipa")
        try FileManager.default.copyItem(at: source, to: local)
        return local
    }

    private static func validPath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"),
              !value.contains("\0") else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let names = value.hasSuffix("/") ? parts.dropLast() : ArraySlice(parts)
        return !names.isEmpty && names.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func infoPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        return parts.count >= 3 && parts[0] == "Payload" &&
            parts[1].hasSuffix(".app") && parts.last == "Info.plist" &&
            (parts[parts.count - 2].hasSuffix(".app") || parts[parts.count - 2].hasSuffix(".appex"))
    }

    private static func metadata(_ entry: Entry, in archive: Archive) throws -> [String: Any] {
        guard entry.uncompressedSize <= 1_048_576 else {
            throw EmberIPAIdentityError.invalid("An Info.plist exceeds the 1 MB metadata limit.")
        }
        var contents = Data()
        _ = try archive.extract(entry) { chunk in
            guard contents.count + chunk.count <= 1_048_576 else {
                throw EmberIPAIdentityError.invalid("An Info.plist exceeds the metadata limit.")
            }
            contents.append(chunk)
        }
        guard let dict = try PropertyListSerialization.propertyList(from: contents, format: nil) as? [String: Any] else {
            throw EmberIPAIdentityError.invalid("The IPA contains an unreadable Info.plist.")
        }
        return dict
    }

    static func inspect(_ source: URL) throws -> EmberIPAStudioOverview {
        let archive = try Archive(url: source, accessMode: .read)
        var host: [String: Any]?
        var hostCount = 0
        var nested: [(String, [String: Any])] = []
        var seen = Set<String>()
        for entry in archive where entry.type == .file {
            guard validPath(entry.path) else {
                throw EmberIPAIdentityError.invalid("Unsafe path in IPA: " + entry.path)
            }
            guard infoPath(entry.path) else { continue }
            guard seen.insert(entry.path).inserted else {
                throw EmberIPAIdentityError.invalid("Duplicate Info.plist: " + entry.path)
            }
            let info = try metadata(entry, in: archive)
            let parts = entry.path.split(separator: "/")
            if parts.count == 3 {
                hostCount += 1
                host = info
            } else {
                nested.append((entry.path, info))
            }
        }
        guard hostCount == 1, let host,
              let id = host["CFBundleIdentifier"] as? String,
              EmberIPAIdentityPolicy.validBundleID(id) else {
            throw EmberIPAIdentityError.invalid("Expected one iPhone app under Payload with a valid bundle identifier.")
        }
        let schemes = (host["CFBundleURLTypes"] as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.joined(separator: ", ")
        let watch = nested.contains { $0.1["WKCompanionAppBundleIdentifier"] as? String == id }
        return .init(
            name: host["CFBundleDisplayName"] as? String ?? host["CFBundleName"] as? String ?? "Imported app",
            identifier: id,
            version: host["CFBundleShortVersionString"] as? String ?? "1.0",
            build: host["CFBundleVersion"] as? String ?? "1",
            minimumIOS: host["MinimumOSVersion"] as? String ?? "",
            urlSchemes: schemes,
            hasWatch: watch,
            nestedIDs: nested.compactMap { $0.1["CFBundleIdentifier"] as? String }
        )
    }

    static func prepare(_ source: URL, edit: EmberIPAIdentityEdit) throws -> URL {
        try EmberIPAIdentityPolicy.validate(edit)
        // Never mutate the imported file. Extract to a unique private directory,
        // check every path before writing, and rebuild a separate unsigned IPA.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("EmberIPAStage-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let archive = try Archive(url: source, accessMode: .read)
        var names = Set<String>()
        var total: UInt64 = 0
        var count = 0
        for entry in archive {
            guard validPath(entry.path), names.insert(entry.path).inserted,
                  entry.type == .file || entry.type == .directory else {
                throw EmberIPAIdentityError.invalid("Unsupported or unsafe IPA entry: " + entry.path)
            }
            guard entry.path.hasPrefix("Payload/") else { continue }
            if entry.type == .directory { continue }
            let size = UInt64(entry.uncompressedSize)
            guard size <= maxEntry, total <= maxTotal - min(maxTotal, size) else {
                throw EmberIPAIdentityError.invalid("IPA exceeds safe extraction limits.")
            }
            total += size
            let target = root.appendingPathComponent(entry.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: target)
            count += 1
        }
        guard count > 0 else { throw EmberIPAIdentityError.invalid("The IPA has no app payload.") }
        let payload = root.appendingPathComponent("Payload")
        let apps = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, let host = apps.first else {
            throw EmberIPAIdentityError.invalid("Expected exactly one iPhone host app.")
        }
        let oldOverview = try inspect(source)
        guard oldOverview.identifier == edit.originalID else {
            throw EmberIPAIdentityError.invalid("The imported IPA identity changed; import it again.")
        }
        guard let walker = fm.enumerator(at: host, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw EmberIPAIdentityError.invalid("Cannot inspect the unpacked app.")
        }
        for case let item as URL in walker {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw EmberIPAIdentityError.invalid("Symbolic links are not supported in edited IPAs.")
            }
            guard values.isRegularFile == true, item.lastPathComponent == "Info.plist",
                  item.deletingLastPathComponent().pathExtension == "app" ||
                  item.deletingLastPathComponent().pathExtension == "appex" else { continue }
            let originalData = try Data(contentsOf: item)
            guard let info = try PropertyListSerialization.propertyList(from: originalData, format: nil) as? [String: Any] else {
                throw EmberIPAIdentityError.invalid("Cannot read nested app metadata.")
            }
            let bundleID = info["CFBundleIdentifier"] as? String ?? ""
            if bundleID != edit.originalID && !bundleID.hasPrefix(edit.originalID + ".") &&
                edit.newID != edit.originalID {
                throw EmberIPAIdentityError.invalid("Nested bundle " + bundleID + " is outside the host namespace. Its identity cannot be safely remapped.")
            }
            let updated = try EmberIPAIdentityPolicy.editedInfo(info, edit: edit, isHost: item.deletingLastPathComponent() == host)
            let data = try PropertyListSerialization.data(fromPropertyList: updated, format: .binary, options: 0)
            try data.write(to: item, options: .atomic)
        }
        let output = fm.temporaryDirectory.appendingPathComponent("EmberIPAEdited-" + UUID().uuidString + ".ipa")
        do {
            let packed = try Archive(url: output, accessMode: .create)
            guard let items = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                throw EmberIPAIdentityError.invalid("Cannot enumerate edited files.")
            }
            var added = 0
            for case let item as URL in items {
                let resource = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard resource.isSymbolicLink != true else { throw EmberIPAIdentityError.invalid("Unexpected symbolic link.") }
                guard resource.isRegularFile == true else { continue }
                let relative = String(item.path.dropFirst(root.path.count + 1))
                guard relative.hasPrefix("Payload/") else { continue }
                try packed.addEntry(with: relative, relativeTo: root, compressionMethod: .deflate)
                added += 1
            }
            guard added > 0 else { throw EmberIPAIdentityError.invalid("No files to package.") }
            // Ensure the rewritten Watch companion and its references remain coherent.
            let verified = try inspect(output)
            guard verified.identifier == edit.newID, verified.hasWatch == oldOverview.hasWatch else {
                throw EmberIPAIdentityError.invalid("Package verification failed after identity edit.")
            }
            return output
        } catch {
            try? fm.removeItem(at: output)
            throw error
        }
    }
}

/// Import -> review/edit -> prepare -> sign/install. Both device types share the
/// same metadata editor, but continue using their existing tested signers.
struct EmberIPAStudioView: View {
    @State private var importing = false
    @State private var busy = false
    @State private var localSource: URL?
    @State private var preparedIPA: URL?
    @State private var overview: EmberIPAStudioOverview?
    @State private var name = ""
    @State private var bundleID = ""
    @State private var version = ""
    @State private var build = ""
    @State private var minimumIOS = ""
    @State private var replaceSchemes = false
    @State private var schemes = ""
    @State private var status = "Import an IPA to inspect it before choosing how to sign."
    @ObservedObject private var watchManager = EmberWatchRefreshManager.shared

    private var edit: EmberIPAIdentityEdit? {
        guard let overview else { return nil }
        return .init(originalID: overview.identifier, newID: bundleID,
                     displayName: name, version: version, build: build,
                     minimumIOS: minimumIOS, replaceURLSchemes: replaceSchemes,
                     urlSchemes: schemes)
    }

    var body: some View {
        List {
            Section("Import") {
                Button { importing = true } label: {
                    Label("Choose IPA from Files", systemImage: "square.and.arrow.down")
                }.disabled(busy)
                if let overview {
                    LabeledContent("App", value: overview.name)
                    LabeledContent("Original Bundle ID", value: overview.identifier)
                    LabeledContent("Contains Apple Watch", value: overview.hasWatch ? "Yes" : "No")
                }
            }
            if let overview {
                Section("Identity") {
                    TextField("Display name", text: $name)
                    TextField("Bundle ID", text: $bundleID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Version", text: $version)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Build", text: $build)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if bundleID != overview.identifier {
                        Label("A different Bundle ID installs as a separate app; it does not preserve existing app data.", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section("Compatibility") {
                    TextField("Minimum iOS", text: $minimumIOS)
                        .keyboardType(.numbersAndPunctuation)
                    Text("Lowering Minimum iOS changes metadata, not the binary's API or architecture requirements.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("URL schemes") {
                    Toggle("Replace URL schemes", isOn: $replaceSchemes)
                    if replaceSchemes {
                        TextField("scheme1, scheme2", text: $schemes)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                if !overview.nestedIDs.isEmpty {
                    Section("Embedded extensions and Watch") {
                        ForEach(overview.nestedIDs, id: \.self) { id in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(id).font(.caption).textSelection(.enabled)
                                if bundleID != overview.identifier {
                                    Text(EmberIPAIdentityPolicy.mappedIdentifier(id, from: overview.identifier, to: bundleID))
                                        .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                        Text("Companion and extension IDs are remapped together before signing. Provisioning profiles must match every target.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Prepare and sign") {
                    Button { prepare() } label: {
                        Label("Prepare edited IPA", systemImage: "slider.horizontal.3")
                    }.disabled(busy || watchManager.isWorking)
                    if let preparedIPA {
                        if overview.hasWatch {
                            Button { installWatch(preparedIPA) } label: {
                                Label("Provision, sign and install iPhone + Watch", systemImage: "applewatch")
                            }.disabled(busy || watchManager.isWorking)
                            Text("Uses your selected Apple Account and separate Watch profiles. Connect LocalDevVPN and unlock the Watch.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Button { importToLibrary(preparedIPA) } label: {
                                Label("Add to Apps for signing", systemImage: "square.stack.3d.up")
                            }.disabled(busy)
                            Text("Then open Apps → imported app → Sign. Choose FlareStore certificate or Apple Account, customize other signing options, and install.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ShareLink(item: preparedIPA) {
                            Label("Share or save prepared IPA", systemImage: "square.and.arrow.up")
                        }
                    }
                    if busy || watchManager.isWorking { ProgressView() }
                    Text(watchManager.isWorking ? watchManager.status : status)
                        .font(.footnote).textSelection(.enabled)
                    Text("Editing breaks any existing code signature. This tool prepares a new unsigned archive; signing must happen afterward. App icons in compiled asset catalogs are not editable here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("IPA Studio")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                importFile(url)
            } catch { status = error.localizedDescription }
        }
        .onDisappear {
            if !busy && !watchManager.isWorking { clearTemporaryFiles() }
        }
    }

    private func clearTemporaryFiles() {
        if let localSource { try? FileManager.default.removeItem(at: localSource) }
        if let preparedIPA { try? FileManager.default.removeItem(at: preparedIPA) }
        localSource = nil
        preparedIPA = nil
    }

    private func importFile(_ url: URL) {
        busy = true
        status = "Reading IPA metadata…"
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let local = try EmberIPAStudioArchive.takeCopy(url)
                    do { return (local, try EmberIPAStudioArchive.inspect(local)) }
                    catch { try? FileManager.default.removeItem(at: local); throw error }
                }.value
                clearTemporaryFiles()
                localSource = result.0
                overview = result.1
                name = result.1.name
                bundleID = result.1.identifier
                version = result.1.version
                build = result.1.build
                minimumIOS = result.1.minimumIOS
                schemes = result.1.urlSchemes
                replaceSchemes = false
                status = "Review the fields, then prepare for signing."
            } catch { status = "Import failed: " + error.localizedDescription }
            busy = false
        }
    }

    private func prepare() {
        guard let edit, let source = localSource else { return }
        busy = true
        status = "Validating and rebuilding the IPA…"
        Task {
            do {
                let file = try await Task.detached(priority: .userInitiated) {
                    try EmberIPAStudioArchive.prepare(source, edit: edit)
                }.value
                if let preparedIPA { try? FileManager.default.removeItem(at: preparedIPA) }
                preparedIPA = file
                status = "Edited IPA is ready. Choose a signing/install route below."
            } catch { status = "Preparation failed: " + error.localizedDescription }
            busy = false
        }
    }

    private func importToLibrary(_ file: URL) {
        busy = true
        defer { busy = false }
        do {
            let id = "EmberIPAStudio-" + UUID().uuidString
            let download = DownloadManager.shared.startArchive(from: file, id: id)
            try DownloadManager.shared.handlePachageFile(url: file, dl: download)
            status = "Imported into Apps. Open Library → Imported, then choose Sign to select a certificate or Apple Account."
        } catch { status = "Library import failed: " + error.localizedDescription }
    }

    private func installWatch(_ file: URL) {
        busy = true
        status = "Provisioning iPhone, Watch and extension targets…"
        Task {
            do {
                try await watchManager.installAndTrack(file: file, sourceURL: "")
                status = "iPhone and Watch installation completed. Verify both apps launch."
            } catch {
                status = "Watch installation failed: " + error.localizedDescription
                EmberErrorCenter.shared.record(error, operation: "IPA Studio Watch install")
            }
            busy = false
        }
    }
}