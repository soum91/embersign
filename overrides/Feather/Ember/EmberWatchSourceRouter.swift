import Foundation
import UIKit
import ZIPFoundation

/// Sends a Sources download that embeds an Apple Watch app through the Watch
/// pipeline (separate iPhone/Watch/widget profiles, iPhone install, watchOS
/// install, repo tracking) instead of Feather's single-profile Library import,
/// which cannot produce an installable Watch app.
enum EmberWatchSourceRouter {
    static func shouldRoute(_ ipa: URL, download: Download?, provenance: SourceAppProvenance?) -> Bool {
        guard download?.onlyArchiving != true,
              ["ipa", "tipa"].contains(ipa.pathExtension.lowercased()),
              let archive = try? Archive(url: ipa, accessMode: .read) else { return false }
        for entry in archive where entry.type == .file {
            guard EmberWatchArchivePolicy.isWatchCompanionInfoPlist(entry.path),
                  entry.uncompressedSize <= 1_048_576 else { continue }
            var data = Data()
            do {
                _ = try archive.extract(entry) { chunk in
                    guard data.count + chunk.count <= 1_048_576 else {
                        throw EmberWatchBundleError.oversizedInfoPlist(entry.path)
                    }
                    data.append(chunk)
                }
                if let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let companion = info["WKCompanionAppBundleIdentifier"] as? String, !companion.isEmpty {
                    return true
                }
            } catch { continue }
        }
        return false
    }

    @MainActor
    static func routeLibraryIfNeeded(_ app: AppInfoPresentable) -> Bool {
        guard let host = Storage.shared.getAppDirectory(for: app),
              let plan = try? EmberWatchBundleInspector.inspect(iphoneApp: host), plan.hasWatchCompanion else { return false }
        let metadata = app.uuid.flatMap { Storage.shared.sourceMetadata(for: $0) }
        let provenance: SourceAppProvenance?
        if let metadata, let url = metadata.sourceRepositoryURL, let id = metadata.sourceAppIdentifier {
            provenance = SourceAppProvenance(sourceRepositoryURL: url,
                sourceRepositoryIdentifier: metadata.sourceRepositoryIdentifier,
                sourceRepositoryName: metadata.sourceRepositoryName,
                sourceAppIdentifier: id, sourceAppName: metadata.sourceAppName,
                sourceAppVersion: metadata.sourceAppVersion,
                sourceAppVersionDate: metadata.sourceAppVersionDate,
                sourceAppDownloadURL: metadata.sourceAppDownloadURL)
        } else { provenance = nil }
        Task { @MainActor in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("EmberWatchLibrary-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                let ipa = try await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    let payload = root.appendingPathComponent("Payload")
                    try fm.createDirectory(at: payload, withIntermediateDirectories: true)
                    try fm.copyItem(at: host, to: payload.appendingPathComponent(host.lastPathComponent))
                    let ipa = root.appendingPathComponent("Watch.ipa")
                    try fm.zipItem(at: payload, to: ipa)
                    return ipa
                }.value
                route(ipa, provenance: provenance) { _ in }
            } catch {
                EmberErrorCenter.shared.record(error, operation: "Watch install from Apps")
                present(title: "Watch install failed", message: error.localizedDescription)
            }
        }
        return true
    }

    static func route(_ ipa: URL, provenance: SourceAppProvenance?, completion: @escaping (Error?) -> Void) {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmberWatchSource-\(UUID()).ipa")
        do {
            try FileManager.default.copyItem(at: ipa, to: copy)
        } catch {
            DispatchQueue.main.async { completion(error) }
            return
        }
        Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: copy) }
            let name = provenance?.sourceAppName ?? provenance?.sourceAppIdentifier ?? "Watch app"
            do {
                if let provenance {
                    try await EmberWatchRefreshManager.shared.installFromSource(file: copy, provenance: provenance)
                } else {
                    try await EmberWatchRefreshManager.shared.installAndTrack(file: copy, sourceURL: "")
                }
                present(title: "\(name) installed",
                        message: "Installed on iPhone and Apple Watch. EmberSign tracks \(provenance?.sourceRepositoryName ?? "its repo") for updates in Apps.")
                completion(nil)
            } catch {
                EmberErrorCenter.shared.record(error, operation: "Watch install from Sources")
                present(title: "\(name) Watch install failed",
                        message: "\(error.localizedDescription)\n\nWatch apps from Sources are signed through Tools > Apple Watch. Keep LocalDevVPN connected, find the paired Watch there once, and keep the Watch unlocked.")
                completion(error)
            }
        }
    }

    @MainActor
    private static func present(title: String, message: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        top.present(alert, animated: true)
    }
}
