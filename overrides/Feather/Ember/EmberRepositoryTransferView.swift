import AltSourceKit
import NimbleJSON
import SwiftUI
import UniformTypeIdentifiers

// Shared, portable repository list format for EmberSign and FlareStorePlus.
// The list contains public feed URLs only, never signing material or credentials.
struct EmberRepositoryListDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }
    static var writableContentTypes: [UTType] { [.json] }

    var urls: [String]

    init(urls: [String]) { self.urls = urls }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw RepositoryListError.unreadableFile
        }
        urls = try RepositoryListCodec.urls(from: string).map(\.absoluteString)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try RepositoryListCodec.export(urls: urls)
        return FileWrapper(regularFileWithContents: data)
    }
}

enum RepositoryListError: LocalizedError {
    case unreadableFile
    case noURLs
    case tooManyURLs

    var errorDescription: String? {
        switch self {
        case .unreadableFile: return "This repository list is not readable UTF-8 text or JSON."
        case .noURLs: return "No valid public HTTP(S) repository URLs found."
        case .tooManyURLs: return "Import up to 200 repositories at a time."
        }
    }
}

enum RepositoryListCodec {
    static func urls(from input: String) throws -> [URL] {
        var candidates: [String] = []
        if let data = input.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            collect(json, into: &candidates)
        }
        // Also accept exported newline-separated lists and raw pasted URLs.
        if candidates.isEmpty {
            let pattern = #"https?://[^\s"'<>\[\]{},]+"#
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let ns = input as NSString
            for match in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
                candidates.append(ns.substring(with: match.range))
            }
        }
        var seen = Set<String>()
        let urls = candidates.compactMap { candidate -> URL? in
            let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ";.,) ").union(.whitespacesAndNewlines))
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  url.host != nil, url.user == nil, url.password == nil else { return nil }
            let key = url.absoluteString
            return seen.insert(key).inserted ? url : nil
        }
        guard !urls.isEmpty else { throw RepositoryListError.noURLs }
        guard urls.count <= 200 else { throw RepositoryListError.tooManyURLs }
        return urls
    }

    private static func collect(_ value: Any, into found: inout [String]) {
        if let string = value as? String {
            found.append(string)
        } else if let array = value as? [Any] {
            array.forEach { collect($0, into: &found) }
        } else if let object = value as? [String: Any] {
            for key in ["url", "sourceURL", "repositoryURL", "repoURL"] {
                if let candidate = object[key] as? String { found.append(candidate); return }
            }
            for key in ["sources", "repositories", "repos"] {
                if let candidates = object[key] { collect(candidates, into: &found) }
            }
        }
    }

    static func export(urls: [String]) throws -> Data {
        let unique = Array(Set(urls)).sorted()
        let object: [String: Any] = [
            "format": "com.soum91.repositories.v1",
            "sources": unique.map { ["url": $0] }
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

// Keep the batch importer independent of the app's signing and bootstrap code.
private enum EmberBatchSourceResolver {
    static func resolve(_ input: String) async throws -> String {
        guard let url = URL(string: input), let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else { return input }
        let path = url.pathComponents.filter { $0 != "/" }
        guard path.count >= 2 else { throw RepositoryListError.noURLs }
        let owner = path[0]
        let repo = path[1]
        guard owner.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
              repo.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            throw RepositoryListError.noURLs
        }
        if path.count >= 5 && (path[2] == "blob" || path[2] == "raw") {
            return "https://raw.githubusercontent.com/\(owner)/\(repo)/\(path[3])/\(path.dropFirst(4).joined(separator: "/"))"
        }
        guard path.count == 2,
              let api = URL(string: "https://api.github.com/repos/\(owner)/\(repo)") else {
            throw RepositoryListError.noURLs
        }
        var request = URLRequest(url: api)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let branch = metadata["default_branch"] as? String else {
            throw RepositoryListError.noURLs
        }
        for name in ["source.json", "repo.json", "apps.json", "app-repo.json", "AltStore.json"] {
            guard let candidate = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(name)") else { continue }
            var probe = URLRequest(url: candidate)
            probe.timeoutInterval = 15
            if let (body, reply) = try? await URLSession.shared.data(for: probe),
               (reply as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               json["apps"] is [[String: Any]] {
                return candidate.absoluteString
            }
        }
        throw RepositoryListError.noURLs
    }
}

struct EmberRepositoryTransferView: View {
    @State private var input = ""
    @State private var isImporting = false
    @State private var showFileImport = false
    @State private var showFileExport = false
    @State private var status = ""

    private var savedURLs: [String] {
        Storage.shared.getSources().compactMap { $0.sourceURL?.absoluteString }.sorted()
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $input)
                    .frame(minHeight: 150)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Repository URLs, one per line, or exported JSON")

                Button("Paste repository list", systemImage: "doc.on.clipboard") {
                    input = UIPasteboard.general.string ?? ""
                }
                Button("Import list from Files", systemImage: "folder") {
                    showFileImport = true
                }
                Button("Import all repositories", systemImage: "square.and.arrow.down") {
                    Task { await importAll() }
                }
                .disabled(isImporting || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Batch import")
            } footer: {
                Text("Paste multiple feed URLs, GitHub repository URLs, or import a .txt/.json list. Existing repositories are skipped; failures remain listed.")
            }

            Section {
                Button("Export \(savedURLs.count) repositories", systemImage: "square.and.arrow.up") {
                    showFileExport = true
                }
                .disabled(savedURLs.isEmpty)
                Button("Copy all URLs", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = savedURLs.joined(separator: "\n")
                    status = "Copied \(savedURLs.count) repository URLs."
                }
                .disabled(savedURLs.isEmpty)
            } header: {
                Text("Export")
            } footer: {
                Text("Exports a portable JSON list of repository URLs only. Certificates, Apple Accounts and passwords are never included.")
            }

            if !status.isEmpty {
                Section("Result") {
                    Text(status).textSelection(.enabled)
                }
            }
            if isImporting {
                Section { ProgressView("Checking repositories...") }
            }
        }
        .navigationTitle("Repository transfer")
        .fileImporter(isPresented: $showFileImport, allowedContentTypes: [.json, .plainText]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard data.count <= 2_000_000, let text = String(data: data, encoding: .utf8) else {
                    throw RepositoryListError.unreadableFile
                }
                input = text
                status = "Loaded repository list. Tap Import all repositories to continue."
            } catch {
                status = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showFileExport,
            document: EmberRepositoryListDocument(urls: savedURLs),
            contentType: .json,
            defaultFilename: "repositories"
        ) { result in
            switch result {
            case .success: status = "Repository list exported."
            case .failure(let error): status = error.localizedDescription
            }
        }
    }

    @MainActor
    private func importAll() async {
        isImporting = true
        defer { isImporting = false }
        do {
            let urls = try RepositoryListCodec.urls(from: input)
            let service = NBFetchService()
            var imported: [URL: ASRepository] = [:]
            var failed: [String] = []
            var skipped = 0
            for url in urls {
                do {
                    let resolved = try await EmberBatchSourceResolver.resolve(url.absoluteString)
                    guard let feedURL = URL(string: resolved) else {
                        throw RepositoryListError.noURLs
                    }
                    let result: Result<ASRepository, Error> = await withCheckedContinuation { continuation in
                        service.fetch(from: feedURL) { (result: Result<ASRepository, Error>) in
                            continuation.resume(returning: result)
                        }
                    }
                    let repo = try result.get()
                    if Storage.shared.sourceExists(repo.id ?? feedURL.absoluteString) {
                        skipped += 1
                    } else {
                        imported[feedURL] = repo
                    }
                } catch {
                    failed.append("\(url.absoluteString): \(error.localizedDescription)")
                }
            }
            if !imported.isEmpty {
                Storage.shared.addSources(repos: imported) { error in
                    if let error { failed.append("Save: \(error.localizedDescription)") }
                }
            }
            status = "Imported \(imported.count), skipped \(skipped), failed \(failed.count)."
                + (failed.isEmpty ? "" : "\n" + failed.joined(separator: "\n"))
        } catch {
            status = error.localizedDescription
        }
    }
}
