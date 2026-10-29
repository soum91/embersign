import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation

/// Watch support preflight. Do not offer an install action until the Watch
/// signing profiles and companion-proxy transport can be independently verified.
struct EmberWatchSupportView: View {
    @State private var isImporting = false
    @State private var isInspecting = false
    @State private var plan: EmberWatchBundlePlan?
    @State private var errorText: String?

    var body: some View {
        List {
            Section("Watch IPA inspection") {
                Button {
                    isImporting = true
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

            Section("Watch installation status") {
                Label("Experimental, not ready to install", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Apple requires a matching development profile and signature for the iPhone app, Watch app, and Watch widgets. An iPhone-only certificate/profile is insufficient.")
                Text("EmberSign's current iPhone installer cannot communicate with the Watch companion service. Installing this IPA to the iPhone alone does not prove that the Watch app was installed.")
                Text("A free Personal Team may be used to test on a registered Watch with short-lived profiles. A certificate purchased for iPhone-only sideloading does not automatically authorize a Watch.")
            }.font(.footnote)
        }
        .navigationTitle("Apple Watch")
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let first = urls.first else { return }
                isInspecting = true
                errorText = nil
                plan = nil
                Task {
                    do {
                        let inspected = try await Task.detached(priority: .userInitiated) {
                            try emberInspectWatchIPA(at: first)
                        }.value
                        plan = inspected
                    } catch {
                        errorText = error.localizedDescription
                    }
                    isInspecting = false
                }
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }

    private func label(for kind: EmberWatchBundlePlan.Target.Kind) -> String {
        switch kind {
        case .iphoneApp: "iPhone app"
        case .watchApp: "Watch app"
        case .watchWidget: "Watch widget"
        }
    }

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
