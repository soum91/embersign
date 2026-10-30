import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation
import Zsign
import IDeviceSwift

private struct EmberIOSBundle: Identifiable {
    let id: String
    let path: String
}

private struct EmberIOSBundlePlan {
    let host: String
    let bundles: [EmberIOSBundle]
}

private enum EmberIOSExtensionInstallError: Error, LocalizedError {
    case unsafeArchive(String)
    case invalidBundle(String)
    case invalidStructure(String)
    case missingProfile(String)
    case signingFailed

    var errorDescription: String? {
        switch self {
        case .unsafeArchive(let value): return "Unsafe IPA archive entry: \(value)"
        case .invalidBundle(let value): return "Bundle identifier is missing or invalid: \(value)"
        case .invalidStructure(let value): return "The IPA is not a valid iPhone app: \(value)"
        case .missingProfile(let value): return "The signed extension has no individual profile: \(value)"
        case .signingFailed: return "The nested-app signing engine rejected this IPA. Check every bundle identifier and signing profile."
        }
    }
}

@MainActor
final class EmberIOSExtensionsModel: ObservableObject {
    @Published var source: URL?
    @Published var status = "Choose an IPA containing an iOS keyboard, Share extension, or widget."
    @Published var bundleIDs: [String] = []
    @Published var busy = false

    func inspect(_ input: URL) async {
        source = input
        busy = true
        defer { busy = false }
        do {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("EmberIOSInspect-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let (_, plan) = try await Task.detached {
                try emberUnpackIOSBundle(input, at: root)
            }.value
            bundleIDs = plan.bundles.map(\.id)
            status = "Found \(bundleIDs.count) distinct targets. Apple requires separate provisioning for each."
        } catch {
            bundleIDs = []
            status = error.localizedDescription
            EmberErrorCenter.shared.record(error, operation: "Inspect iOS extensions")
        }
    }

    func signAndInstall() async {
        guard let source, !busy else { return }
        busy = true
        defer { busy = false }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberIOSSigning-\(UUID())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            status = "Inspecting nested application bundles…"
            let (host, plan) = try await Task.detached {
                try emberUnpackIOSBundle(source, at: root)
            }.value
            guard plan.bundles.count >= 2 else {
                throw EmberIOSExtensionInstallError.invalidStructure("There is no embedded iOS extension.")
            }
            bundleIDs = plan.bundles.map(\.id)
            status = "Provisioning \(plan.bundles.count) Apple App IDs and individual profiles…"
            let identity = try await EmberAccountManager.shared.provisionIOSExtensionBundleSet(
                bundleIDs: bundleIDs
            )
            status = "Signing every extension and the containing app…"
            let signed = try await Task.detached {
                try emberSignIOSExtensionBundle(host: host, plan: plan,
                                                identity: identity, root: root)
            }.value
            status = "Installing verified app and keyboard extensions…"
            let installer = InstallationProxy(viewModel: InstallerStatusViewModel(isIdevice: true))
            try await installer.install(at: signed)
            status = "Installer accepted the signed IPA. Open iPhone Settings → General → Keyboard → Keyboards to enable Aukkhor."
        } catch {
            status = error.localizedDescription
            EmberErrorCenter.shared.record(error, operation: "Sign and install iOS extensions")
        }
    }
}

struct EmberIOSExtensionsView: View {
    @StateObject private var model = EmberIOSExtensionsModel()
    @State private var importing = false

    var body: some View {
        List {
            Section("App + extension signing") {
                Button { importing = true } label: {
                    Label("Select keyboard or widget IPA", systemImage: "square.and.arrow.down")
                }.disabled(model.busy)
                if let source = model.source {
                    LabeledContent("IPA", value: source.lastPathComponent)
                }
                ForEach(Array(model.bundleIDs.enumerated()), id: \.offset) { index, bundle in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(index == 0 ? "Containing app" : "Embedded extension \(index)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(bundle).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
                Button {
                    Task { await model.signAndInstall() }
                } label: {
                    if model.busy {
                        Label("Processing…", systemImage: "hourglass")
                    } else {
                        Label("Provision all, sign and install", systemImage: "checkmark.seal")
                    }
                }.disabled(model.busy || model.bundleIDs.count < 2)
                Text(model.status).font(.footnote).textSelection(.enabled)
            }
            Section("Signing requirements") {
                Text("An iOS app containing a keyboard or Share extension has multiple bundle identifiers. The host app's provisioning profile cannot simply be reused for its extensions.")
                Text("EmberSign creates matching App IDs and individual profiles using your authorized Apple Account, then signs the nested targets using its multi-profile signing engine. This may use several Personal Team App ID slots.")
                Text("If Apple rejects the registration or provisioning request, EmberSign shows the actual failure rather than exporting an IPA that cannot install.")
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("iOS app extensions")
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.data, .zip, UTType(filenameExtension: "ipa") ?? .data],
                      allowsMultipleSelection: false) { outcome in
            do {
                guard let file = try outcome.get().first else { return }
                Task { await model.inspect(file) }
            } catch {
                model.status = error.localizedDescription
            }
        }
    }
}

// This extractor intentionally refuses untrusted traversal, duplicate file entries,
// symlinks, huge archive entries and non-iPhone payload layouts.
private func emberUnpackIOSBundle(_ source: URL, at root: URL) throws -> (URL, EmberIOSBundlePlan) {
    let manager = FileManager.default
    let access = source.startAccessingSecurityScopedResource()
    defer { if access { source.stopAccessingSecurityScopedResource() } }
    let original = root.appendingPathComponent("original.ipa")
    try manager.copyItem(at: source, to: original)
    let archive = try Archive(url: original, accessMode: .read)
    let contents = root.appendingPathComponent("contents", isDirectory: true)
    try manager.createDirectory(at: contents, withIntermediateDirectories: true)
    var seen = Set<String>()
    var total: UInt64 = 0
    for entry in archive {
        let path = entry.path
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              !pieces.isEmpty, pieces.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw EmberIOSExtensionInstallError.unsafeArchive(path)
        }
        guard pieces.first == "Payload" else { continue }
        if entry.type == .directory { continue }
        guard pieces.count >= 3, pieces[1].hasSuffix(".app"),
              entry.type == .file, seen.insert(path).inserted else {
            throw EmberIOSExtensionInstallError.unsafeArchive(path)
        }
        let length = UInt64(entry.uncompressedSize)
        total += length
        guard length <= 128 * 1024 * 1024, total <= 512 * 1024 * 1024 else {
            throw EmberIOSExtensionInstallError.unsafeArchive("Package too large.")
        }
        let target = contents.appendingPathComponent(path)
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try archive.extract(entry, to: target)
    }
    let payload = contents.appendingPathComponent("Payload")
    let apps = try manager.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "app" }
    guard apps.count == 1, let host = apps.first else {
        throw EmberIOSExtensionInstallError.invalidStructure("Expected one host app.")
    }
    func identifier(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String,
              id.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else {
            throw EmberIOSExtensionInstallError.invalidBundle(url.lastPathComponent)
        }
        return id
    }
    let hostID = try identifier(host)
    var bundles = [EmberIOSBundle(id: hostID, path: ".")]
    let pluginDir = host.appendingPathComponent("PlugIns")
    let children = (try? manager.contentsOfDirectory(at: pluginDir, includingPropertiesForKeys: nil)) ?? []
    for extensionURL in children.filter({ $0.pathExtension == "appex" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let id = try identifier(extensionURL)
        guard id.hasPrefix(hostID + "."), !bundles.contains(where: { $0.id == id }) else {
            throw EmberIOSExtensionInstallError.invalidBundle(id)
        }
        bundles.append(.init(id: id, path: "PlugIns/" + extensionURL.lastPathComponent))
    }
    guard bundles.count <= 8 else {
        throw EmberIOSExtensionInstallError.invalidStructure("Too many extensions.")
    }
    return (host, EmberIOSBundlePlan(host: hostID, bundles: bundles))
}

private func emberSignIOSExtensionBundle(
    host: URL, plan: EmberIOSBundlePlan, identity: EmberWatchSigningIdentity, root: URL
) throws -> URL {
    let manager = FileManager.default
    let cert = root.appendingPathComponent("IOSSigning.p12")
    try identity.p12.write(to: cert, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    var profilePaths: [String] = []
    for (index, target) in plan.bundles.enumerated() {
        guard let data = identity.profiles[target.id], !data.isEmpty else {
            throw EmberIOSExtensionInstallError.missingProfile(target.id)
        }
        let profile = root.appendingPathComponent("IOSProfile-\(index).mobileprovision")
        try data.write(to: profile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        profilePaths.append(profile.path)
    }
    guard Zsign.sign(appPath: host.path, provisionPath: profilePaths.joined(separator: "\n"),
                     p12Path: cert.path, p12Password: "", removeProvision: true) else {
        throw EmberIOSExtensionInstallError.signingFailed
    }
    for target in plan.bundles {
        let bundle = host.appendingPathComponent(target.path)
        guard manager.fileExists(atPath: bundle.appendingPathComponent("embedded.mobileprovision").path),
              manager.fileExists(atPath: bundle.appendingPathComponent("_CodeSignature/CodeResources").path) else {
            throw EmberIOSExtensionInstallError.missingProfile(target.id)
        }
    }
    let contents = root.appendingPathComponent("contents", isDirectory: true)
    let signed = root.appendingPathComponent("EmberIOS-extensions-signed.ipa")
    let archive = try Archive(url: signed, accessMode: .create)
    guard let enumerator = manager.enumerator(at: contents, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
        throw EmberIOSExtensionInstallError.invalidStructure("Could not package signed app.")
    }
    var count = 0
    for case let file as URL in enumerator {
        let attrs = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attrs.isSymbolicLink != true else {
            throw EmberIOSExtensionInstallError.unsafeArchive(file.lastPathComponent)
        }
        guard attrs.isRegularFile == true else { continue }
        let relative = String(file.path.dropFirst(contents.path.count + 1))
        guard relative.hasPrefix("Payload/") else { continue }
        try archive.addEntry(with: relative, relativeTo: contents, compressionMethod: .deflate)
        count += 1
    }
    guard count > 0 else {
        throw EmberIOSExtensionInstallError.invalidStructure("No signed files to package.")
    }
    return signed
}
