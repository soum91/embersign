import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import ZIPFoundation
import EmberPairingNative
import Zsign
import IDeviceSwift

@MainActor
private final class EmberWatchProgress: ObservableObject {
    static let shared = EmberWatchProgress()
    @Published var status = "Connect LocalDevVPN and use your saved remote pairing file."
}

/// Inspect and transfer an already provisioned Watch app via the companion
/// proxy. A Watch signing profile is distinct from an iPhone signing profile.
struct EmberWatchSupportView: View {
    private enum IPASelection { case inspect, signed, provision }
    @State private var selection: IPASelection = .inspect
    @State private var isSelectingIPA = false
    @State private var isShowingOperationError = false
    @State private var isInspecting = false
    @State private var isDiscovering = false
    @State private var isInstalling = false
    @State private var isSigning = false
    @State private var watchIDs: [String] = []
    @State private var iphoneUDID: String?
    @State private var plan: EmberWatchBundlePlan?
    @State private var errorText: String?
    @ObservedObject private var watchProgress = EmberWatchProgress.shared
    @AppStorage("EmberSign.jit.endpoint.deviceIP") private var deviceIP = "10.7.0.1"
    @AppStorage("EmberSign.jit.endpoint.port") private var devicePort = 49152

    var body: some View {
        List {
            Section("Watch IPA inspection") {
                Button {
                    selection = .inspect
                    isSelectingIPA = true
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

            Section("Paired Watch connection") {
                TextField("LocalDevVPN Device IP", text: $deviceIP)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Remote pairing port", value: $devicePort, format: .number)
                    .keyboardType(.numberPad)
                Button {
                    discoverWatches()
                } label: {
                    HStack {
                        Label("Find paired Apple Watch", systemImage: "applewatch")
                        Spacer()
                        if isDiscovering { ProgressView() }
                    }
                }.disabled(isDiscovering || isInstalling || isSigning)
                ForEach(watchIDs, id: \.self) { id in
                    LabeledContent("Paired Watch UDID", value: id)
                        .font(.caption).textSelection(.enabled)
                }
                Text("Uses the existing EmberSign remote-pairing file. Keep the Watch unlocked, near the iPhone, and LocalDevVPN connected.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Sign and install Watch IPA") {
                if EmberAccountManager.shared.accounts.isEmpty {
                    NavigationLink {
                        EmberAccountsView()
                    } label: {
                        Label("Add Apple Account for Watch provisioning", systemImage: "person.crop.circle.badge.plus")
                    }
                } else {
                    Button {
                        selection = .provision
                        watchProgress.status = "Choose an unsigned iPhone IPA containing its Watch companion."
                        isSelectingIPA = true
                    } label: {
                        HStack {
                            Label("Provision, sign and install IPA", systemImage: "checkmark.shield")
                            Spacer()
                            if isSigning { ProgressView() }
                        }
                    }
                    .disabled(watchIDs.count != 1 || iphoneUDID == nil || isSigning || isInstalling || isDiscovering)
                    if isSigning { ProgressView().padding(.vertical, 4) }
                    Text(watchProgress.status)
                        .font(.footnote).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let errorText {
                        Text(errorText)
                            .font(.footnote).foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Text("This route requests a development certificate through your selected Apple Account. It does not require a certificate in the imported Certificates list.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("First tap Find paired Apple Watch, then choose the unsigned WristPane IPA. EmberSign will request three development profiles, sign the nested bundles, install the iPhone app, then send the Watch app to watchOS.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section("Install already signed Watch companion") {
                Button {
                    selection = .signed
                    isSelectingIPA = true
                } label: {
                    HStack {
                        Label("Install signed Watch IPA", systemImage: "square.and.arrow.down")
                        Spacer()
                        if isInstalling { ProgressView() }
                    }
                }.disabled(isDiscovering || isInstalling || isSigning)
                Text(watchProgress.status).font(.footnote).textSelection(.enabled)
                Label("Experimental Watch transport", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("If your IPA was already signed with matching iPhone and Watch profiles, install its iPhone host through Apps, then select that same IPA here to transfer its Watch companion. This does not uninstall your existing Watch app.")
                Text("An iPhone-only FlareStore profile cannot sign the Watch. Use the Apple Account path above for an unsigned IPA.")
            }.font(.footnote)
        }
        .navigationTitle("Apple Watch")
        .sheet(isPresented: $isSelectingIPA) {
            EmberWatchNativeIPAPicker(
                onPick: { file in
                    isSelectingIPA = false
                    acceptSelectedIPA(file)
                },
                onCancel: {
                    isSelectingIPA = false
                    watchProgress.status = "IPA selection cancelled."
                }
            )
        }
        .alert("Apple Watch operation failed", isPresented: $isShowingOperationError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorText ?? "Unknown error")
        }
    }

    private func acceptSelectedIPA(_ file: URL) {
        guard file.pathExtension.lowercased() == "ipa" else {
            showOperationError(EmberError.message("Choose an .ipa file, not \(file.lastPathComponent)."))
            return
        }
        watchProgress.status = "Received \(file.lastPathComponent) from Files."
        switch selection {
        case .inspect:
            isInspecting = true
            errorText = nil
            plan = nil
            Task {
                do {
                    let inspected = try await Task.detached(priority: .userInitiated) {
                        try emberInspectWatchIPA(at: file)
                    }.value
                    plan = inspected
                } catch {
                    showOperationError(error)
                }
                isInspecting = false
            }
        case .signed:
            installSignedIPA(file)
        case .provision:
            signAndInstallIPA(file)
        }
    }

    private func showOperationError(_ error: Error) {
        errorText = error.localizedDescription
        watchProgress.status = "Watch operation failed. See error details."
        isShowingOperationError = true
    }

    private func discoverWatches() {
        guard !isDiscovering else { return }
        let endpoint = deviceIP
        let port = devicePort
        isDiscovering = true
        errorText = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[String], Error> in
                do {
                    let pairing = try EmberPairingStore.read()
                    guard pairing.kind == .remote else {
                        throw EmberError.message("Import an RSD remote pairing record in Tools > Pairing file.")
                    }
                    guard (1...65535).contains(port) else { throw EmberError.message("Invalid pairing port.") }
                    var devices: UnsafeMutablePointer<CChar>?
                    var phone: UnsafeMutablePointer<CChar>?
                    var detail: UnsafeMutablePointer<CChar>?
                    let code = EmberPairingStore.url.path.withCString { path in
                        endpoint.withCString { ip in
                            embersign_watch_discover(path, ip, UInt16(port), &phone, &devices, &detail)
                        }
                    }
                    let phoneID = Self.consumeNative(phone)
                    let list = Self.consumeNative(devices)
                    let issue = Self.consumeNative(detail)
                    guard code == 0 else { throw EmberError.message(issue ?? "Watch discovery failed") }
                    guard let phoneID, !phoneID.isEmpty else { throw EmberError.message("Cannot read this iPhone's UDID.") }
                    return .success([phoneID] + (list ?? "").split(separator: ",").map(String.init))
                } catch { return .failure(error) }
            }.value
            isDiscovering = false
            switch outcome {
            case .success(let ids):
                iphoneUDID = ids.first
                watchIDs = Array(ids.dropFirst())
                watchProgress.status = watchIDs.isEmpty ? "No Apple Watch is paired or reachable." : "Found \(watchIDs.count) paired Apple Watch device(s)."
            case .failure(let error):
                showOperationError(error)
            }
        }
    }

    private func installSignedIPA(_ file: URL) {
        guard !isInstalling else { return }
        let endpoint = deviceIP
        let port = devicePort
        isInstalling = true
        errorText = nil
        watchProgress.status = "Checking Watch provisioning and code signatures…"
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do {
                    guard (1...65535).contains(port) else { throw EmberError.message("Invalid remote pairing port.") }
                    let pairing = try EmberPairingStore.read()
                    guard pairing.kind == .remote else {
                        throw EmberError.message("Import an RSD remote pairing record in Tools > Pairing file.")
                    }
                    let hostID = Self.savedWatchIdentifier("EmberSign.watch.hostID")
                    let systemBUID = Self.savedWatchIdentifier("EmberSign.watch.systemBUID")
                    let message = try emberInstallSignedWatchIPA(
                        at: file, pairingURL: EmberPairingStore.url,
                        deviceIP: endpoint, devicePort: UInt16(port),
                        hostID: hostID, systemBUID: systemBUID
                    )
                    return .success(message)
                } catch { return .failure(error) }
            }.value
            isInstalling = false
            switch outcome {
            case .success(let message): watchProgress.status = message
            case .failure(let error):
                showOperationError(error)
            }
        }
    }

    private func signAndInstallIPA(_ file: URL) {
        guard !isSigning else { return }
        guard watchIDs.count == 1, let watchID = watchIDs.first,
              let phoneID = iphoneUDID, (1...65535).contains(devicePort) else {
            showOperationError(EmberError.message("Find exactly one paired Apple Watch using a valid LocalDevVPN endpoint before selecting an IPA."))
            return
        }
        let endpoint = deviceIP
        let port = devicePort
        let hostID = Self.savedWatchIdentifier("EmberSign.watch.hostID")
        let systemBUID = Self.savedWatchIdentifier("EmberSign.watch.systemBUID")
        isSigning = true
        errorText = nil
        watchProgress.status = "Extracting Watch IPA…"
        Task {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("EmberWatchSigning-\(UUID())", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let (host, plan) = try await Task.detached(priority: .userInitiated) {
                    try emberExtractWatchIPA(at: file, into: root)
                }.value
                guard plan.hasWatchCompanion else {
                    throw EmberError.message("This IPA does not contain an Apple Watch companion.")
                }
                watchProgress.status = "Getting iPhone and Watch provisioning profiles from Apple…"
                let signing = try await EmberAccountManager.shared.provisionWatchCompanion(
                    plan: plan, iphoneUDID: phoneID, watchUDID: watchID
                )
                watchProgress.status = "Signing iPhone, Apple Watch and widgets…"
                let package = try await Task.detached(priority: .userInitiated) {
                    try emberSignWatchIPA(host: host, plan: plan, identity: signing, root: root)
                }.value
                watchProgress.status = "Installing the signed iPhone host…"
                let installer = InstallationProxy(viewModel: InstallerStatusViewModel(isIdevice: true))
                try await installer.install(at: package)
                watchProgress.status = "Installing companion on paired Apple Watch…"
                let message = try await Task.detached(priority: .userInitiated) {
                    try emberStreamWatchBundle(host: host, plan: plan, pairingURL: EmberPairingStore.url,
                                               deviceIP: endpoint, devicePort: UInt16(port),
                                               hostID: hostID, systemBUID: systemBUID)
                }.value
                watchProgress.status = message
            } catch {
                showOperationError(error)
                EmberErrorCenter.shared.record(error, operation: "Apple Watch installation")
            }
            isSigning = false
        }
    }

    nonisolated private static func savedWatchIdentifier(_ key: String) -> String {
        if let saved = UserDefaults.standard.string(forKey: key), UUID(uuidString: saved) != nil { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    nonisolated private static func consumeNative(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { embersign_pair_free_string(pointer) }
        return String(cString: pointer)
    }

    private func label(for kind: EmberWatchBundlePlan.Target.Kind) -> String {
        switch kind {
        case .iphoneApp: "iPhone app"
        case .watchApp: "Watch app"
        case .watchWidget: "Watch widget"
        }
    }

}

private struct EmberWatchNativeIPAPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Use the system's broad file type, then validate .ipa explicitly.
        // Dynamic IPA UTTypes can prevent the SwiftUI file importer from
        // delivering a selection for an otherwise valid archive.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let first = urls.first else { onCancel(); return }
            onPick(first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

private func emberInstallSignedWatchIPA(
    at file: URL, pairingURL: URL, deviceIP: String, devicePort: UInt16,
    hostID: String, systemBUID: String
) throws -> String {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("EmberWatchTransfer-\(UUID())", isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let (host, plan) = try emberExtractWatchIPA(at: file, into: root)
    try emberVerifySignedWatch(host: host, plan: plan)
    return try emberStreamWatchBundle(host: host, plan: plan, pairingURL: pairingURL,
                                     deviceIP: deviceIP, devicePort: devicePort,
                                     hostID: hostID, systemBUID: systemBUID)
}

private func emberExtractWatchIPA(at file: URL, into root: URL) throws -> (URL, EmberWatchBundlePlan) {
    guard file.pathExtension.lowercased() == "ipa" else { throw EmberError.message("Select an .ipa archive.") }
    let access = file.startAccessingSecurityScopedResource()
    defer { if access { file.stopAccessingSecurityScopedResource() } }
    let manager = FileManager.default
    let copied = root.appendingPathComponent("original.ipa")
    try manager.copyItem(at: file, to: copied)
    let archive = try Archive(url: copied, accessMode: .read)
    let unpacked = root.appendingPathComponent("contents", isDirectory: true)
    try manager.createDirectory(at: unpacked, withIntermediateDirectories: true)
    var seen = Set<String>()
    var total: UInt64 = 0
    for entry in archive {
        let path = entry.path
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
            throw EmberWatchBundleError.unsafeArchivePath(path)
        }
        guard pieces.first == "Payload" else { continue }
        guard pieces.count >= 2, pieces[1].hasSuffix(".app") else {
            throw EmberWatchBundleError.unsafeArchivePath(path)
        }
        if entry.type == .directory { continue }
        guard entry.type == .file, seen.insert(path).inserted else {
            throw EmberWatchBundleError.unsafeArchivePath(path)
        }
        let size = UInt64(entry.uncompressedSize)
        total += size
        guard size <= 128 * 1024 * 1024, total <= 1024 * 1024 * 1024 else {
            throw EmberError.message("Watch IPA exceeds safe extraction limits.")
        }
        let target = unpacked.appendingPathComponent(path)
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try archive.extract(entry, to: target)
    }
    let hostBundles = try manager.contentsOfDirectory(at: unpacked.appendingPathComponent("Payload"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "app" }
    guard hostBundles.count == 1, let host = hostBundles.first else {
        throw EmberError.message("Expected exactly one signed iPhone host app in Payload/.")
    }
    let plan = try EmberWatchBundleInspector.inspect(iphoneApp: host)
    return (host, plan)
}

private func emberVerifySignedWatch(host: URL, plan: EmberWatchBundlePlan) throws {
    let manager = FileManager.default
    let watches = plan.targets.filter { $0.kind == .watchApp }
    guard watches.count == 1 else {
        throw EmberError.message("Expected exactly one Apple Watch companion in the IPA.")
    }
    for target in plan.targets {
        let bundle = host.appendingPathComponent(target.relativePath)
        guard manager.fileExists(atPath: bundle.appendingPathComponent("embedded.mobileprovision").path),
              manager.fileExists(atPath: bundle.appendingPathComponent("_CodeSignature/CodeResources").path) else {
            throw EmberWatchBundleError.missingProfile(target.bundleID)
        }
    }
}

private func emberStreamWatchBundle(
    host: URL, plan: EmberWatchBundlePlan, pairingURL: URL,
    deviceIP: String, devicePort: UInt16, hostID: String, systemBUID: String
) throws -> String {
    guard let watch = plan.targets.first(where: { $0.kind == .watchApp }) else {
        throw EmberError.message("The signed IPA contains no Watch app.")
    }
    let watchURL = host.appendingPathComponent(watch.relativePath)
    var nativeError: UnsafeMutablePointer<CChar>?
    let result = pairingURL.path.withCString { pairing in
        deviceIP.withCString { ip in
            hostID.withCString { host in
                systemBUID.withCString { buid in
                    watchURL.path.withCString { app in
                        embersign_watch_install_signed(pairing, ip, devicePort, host, buid, app, { status, _ in
                            guard let status else { return }
                            let message = String(cString: status)
                            Task { @MainActor in EmberWatchProgress.shared.status = message }
                        }, nil, &nativeError)
                    }
                }
            }
        }
    }
    let failureText: String? = nativeError.map { pointer in
        defer { embersign_pair_free_string(pointer) }
        return String(cString: pointer)
    }
    guard result == 0 else { throw EmberError.message(failureText ?? "Watch transfer failed") }
    return "Watch transfer completed. Confirm the app opens on your Watch and its widgets appear."
}

private func emberSignWatchIPA(
    host: URL, plan: EmberWatchBundlePlan,
    identity: EmberWatchSigningIdentity, root: URL
) throws -> URL {
    try plan.validateProfiles(identity.profiles)
    let fm = FileManager.default
    let certificate = root.appendingPathComponent("WatchSigning.p12")
    try identity.p12.write(to: certificate, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    var profilePaths: [String] = []
    for (index, target) in plan.targets.enumerated() {
        guard let data = identity.profiles[target.bundleID], !data.isEmpty else {
            throw EmberWatchBundleError.missingProfile(target.bundleID)
        }
        let profile = root.appendingPathComponent("WatchProfile-\(index).mobileprovision")
        try data.write(to: profile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        profilePaths.append(profile.path)
    }
    // The pinned Zsign C++ engine matches profiles by bundle identifier.
    // EmberSign's build-time shim exposes the existing multi-profile engine
    // through a newline-delimited provisionPath. Single-profile callers are
    // untouched and each nested bundle receives its OWN embedded profile.
    guard Zsign.sign(appPath: host.path, provisionPath: profilePaths.joined(separator: "\n"),
                     p12Path: certificate.path, p12Password: "", removeProvision: true) else {
        throw EmberError.message("Zsign rejected the iPhone, Watch or widget signing targets.")
    }
    try emberVerifySignedWatch(host: host, plan: plan)

    let contents = root.appendingPathComponent("contents", isDirectory: true)
    let signed = root.appendingPathComponent("EmberWatch-signed.ipa")
    let archive = try Archive(url: signed, accessMode: .create)
    guard let enumerator = fm.enumerator(at: contents, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
        throw EmberError.message("Cannot enumerate the signed app for packaging.")
    }
    var count = 0
    for case let item as URL in enumerator {
        let resource = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard resource.isSymbolicLink != true else {
            throw EmberError.message("Signed IPA contains an unsupported symbolic link.")
        }
        guard resource.isRegularFile == true else { continue }
        let relative = String(item.path.dropFirst(contents.path.count + 1))
        guard relative.hasPrefix("Payload/") else { continue }
        try archive.addEntry(with: relative, relativeTo: contents, compressionMethod: .deflate)
        count += 1
    }
    guard count > 0 else { throw EmberError.message("Signed IPA has no files to package.") }
    return signed
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
