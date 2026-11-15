import Foundation
import UIKit
import ZIPFoundation

/// Sends a Sources download that embeds an Apple Watch app through the Watch
/// pipeline (separate iPhone/Watch/widget profiles, iPhone install, watchOS
/// install, repo tracking) instead of Feather's single-profile Library import,
/// which cannot produce an installable Watch app.
enum EmberWatchSourceRouter {
    static func shouldRoute(_ ipa: URL, download: Download?, provenance: SourceAppProvenance?) -> Bool {
        guard provenance != nil, download?.onlyArchiving != true,
              ipa.pathExtension.lowercased() == "ipa",
              let archive = try? Archive(url: ipa, accessMode: .read) else { return false }
        for entry in archive where entry.type == .file {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 5, parts[0] == "Payload", parts[1].hasSuffix(".app"),
               parts[2] == "Watch", parts[3].hasSuffix(".app"), parts[4] == "Info.plist" {
                return true
            }
        }
        return false
    }

    static func route(_ ipa: URL, provenance: SourceAppProvenance, completion: @escaping (Error?) -> Void) {
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
            let name = provenance.sourceAppName ?? provenance.sourceAppIdentifier
            do {
                try await EmberWatchRefreshManager.shared.installFromSource(file: copy, provenance: provenance)
                present(title: "\(name) installed",
                        message: "Installed on iPhone and Apple Watch. EmberSign tracks \(provenance.sourceRepositoryName ?? "its repo") for updates under Tools > Apple Watch.")
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
