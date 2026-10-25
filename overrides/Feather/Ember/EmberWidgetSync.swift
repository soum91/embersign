import Foundation
import CoreData
import WidgetKit
import SwiftUI
import UniformTypeIdentifiers
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
