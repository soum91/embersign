import Foundation
import CoreData
import WidgetKit
import SwiftUI
import UniformTypeIdentifiers
import AppIntents
import NimbleViews

enum EmberQuickDestination: String, Identifiable { case importIPA, library; var id: String { rawValue } }
@MainActor final class EmberQuickRouter: ObservableObject {
    static let shared = EmberQuickRouter()
    @Published var destination: EmberQuickDestination?
}
struct EmberQuickSheet: View {
    var destination: EmberQuickDestination
    var body: some View {
        if destination == .library { LibraryView() }
        else {
            FileImporterRepresentableView(allowedContentTypes: [.ipa, .tipa], allowsMultipleSelection: true, onDocumentsPicked: { urls in
                for url in urls {
                    let manager = DownloadManager.shared
                    let dl = manager.startArchive(from: url, id: "FeatherManualDownload_\(UUID().uuidString)")
                    try? manager.handlePachageFile(url: url, dl: dl)
                }
            }).ignoresSafeArea()
        }
    }
}
@MainActor enum EmberWidgetSync {
    static func refresh() {
        let storage = Storage.shared
        let request: NSFetchRequest<Signed> = Signed.fetchRequest()
        let signed = (try? storage.context.fetch(request)) ?? []
        let entries = signed.compactMap { app -> EmberAppEntity? in
            guard let id = app.identifier else { return nil }
            var expiry = app.certificate?.expiration
            if let dir = storage.getAppDirectory(for: app) {
                let profile = dir.appendingPathComponent("embedded.mobileprovision")
                if FileManager.default.fileExists(atPath: profile.path), let embeddedExpiry = CertificateReader(profile).decoded?.ExpirationDate {
                    expiry = expiry.map { min($0, embeddedExpiry) } ?? embeddedExpiry
                }
            }
            return EmberAppEntity(id: id, name: app.name ?? id, expiry: expiry)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        AppGroup.write(EmberWidgetState(apps: entries, updatedAt: .now), "ember-widget.json")
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) { ControlCenter.shared.reloadAllControls() }
    }
}


/// App-only shortcuts avoid the sideloaded Control Widget host for these actions.
struct EmberImportShortcutIntent: AppIntent {
    static var title: LocalizedStringResource = "Import IPA with EmberSign"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        EmberQuickRouter.shared.destination = .importIPA
        return .result()
    }
}
struct EmberLibraryShortcutIntent: AppIntent {
    static var title: LocalizedStringResource = "Open EmberSign Library"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        EmberQuickRouter.shared.destination = .library
        return .result()
    }
}
struct EmberJITShortcutIntent: AppIntent {
    static var title: LocalizedStringResource = "Open EmberSign JIT Tools"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        EmberJITService.shared.present(bundleID: "")
        return .result()
    }
}
struct EmberSignShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .orange

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: EmberImportShortcutIntent(), phrases: [
            "Import an IPA in \(.applicationName)",
        ], shortTitle: "Import IPA", systemImageName: "square.and.arrow.down")
        AppShortcut(intent: EmberLibraryShortcutIntent(), phrases: [
            "Open my app library in \(.applicationName)",
        ], shortTitle: "App Library", systemImageName: "square.grid.2x2.fill")
        AppShortcut(intent: EmberJITShortcutIntent(), phrases: [
            "Open JIT tools in \(.applicationName)",
        ], shortTitle: "JIT Tools", systemImageName: "bolt.fill")
    }
}
