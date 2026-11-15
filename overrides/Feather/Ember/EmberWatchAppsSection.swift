import SwiftUI

/// Watch installs use the same per-target signing pipeline from Sources and Apps.
/// Their tracking records are separate from Feather's single-profile signed entries.
struct EmberWatchAppsSection: View {
    @ObservedObject private var manager = EmberWatchRefreshManager.shared
    var searchText: String = ""

    private var apps: [EmberWatchTrackedApp] {
        manager.trackedApps.filter {
            searchText.isEmpty || $0.bundleID.localizedCaseInsensitiveContains(searchText)
                || ($0.name ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        if !apps.isEmpty {
            Section("iPhone + Apple Watch") {
                ForEach(apps, id: \.bundleID) { app in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(app.name ?? (app.bundleID == "dev.watchlink.companion" ? "WatchLink" : app.bundleID),
                              systemImage: "applewatch")
                        Text("\(app.version) (\(app.build))").font(.caption).foregroundStyle(.secondary)
                        Button("Update or re-sign on iPhone + Watch") {
                            Task { _ = await manager.refresh(app, force: true) }
                        }
                        .buttonStyle(.borderless)
                        .disabled(manager.isWorking || manager.isChecking)
                    }
                }
                if manager.isWorking || manager.isChecking { ProgressView() }
                Text(manager.status).font(.caption).textSelection(.enabled)
            }
        }
    }
}
