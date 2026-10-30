import Foundation
import SwiftUI
import CoreData
import IDeviceSwift
import UIKit

@MainActor
final class EmberAutoRefreshManager: ObservableObject {
    static let shared = EmberAutoRefreshManager()
    @Published var isRunning = false
    @Published var status = "Auto refresh runs when iOS gives EmberSign background time and the pairing tunnel is reachable."
    @Published var lastRun: Date? = UserDefaults.standard.object(forKey: "EmberSign.lastRefresh") as? Date

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "EmberSign.autoRefresh") }
        set {
            UserDefaults.standard.set(newValue, forKey: "EmberSign.autoRefresh")
            configure()
            objectWillChange.send()
        }
    }

    var thresholdDays: Int {
        get { max(1, UserDefaults.standard.integer(forKey: "EmberSign.refreshThreshold") == 0 ? 2 : UserDefaults.standard.integer(forKey: "EmberSign.refreshThreshold")) }
        set { UserDefaults.standard.set(newValue, forKey: "EmberSign.refreshThreshold"); objectWillChange.send() }
    }

    func configure() {
        let shouldFetch = enabled || EmberWatchRefreshManager.shared.enabled
        UIApplication.shared.setMinimumBackgroundFetchInterval(shouldFetch ? 6 * 60 * 60 : UIApplication.backgroundFetchIntervalNever)
    }

    func refreshAll(force: Bool = false) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        defer { isRunning = false }
        let apps: [Signed] = (enabled || force) ? signedApps().filter { app in
            guard let bundleID = app.identifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  EmberAccountManager.shared.accountID(for: bundleID) != nil else { return false }
            if force { return true }
            guard let expiry = Storage.shared.getCertificate(from: app)?.expiration else { return true }
            return expiry.timeIntervalSinceNow <= Double(thresholdDays) * 86_400
        } : []

        var failures = 0
        for app in apps {
            guard let bundleID = app.identifier else { continue }
            do {
                status = "Refreshing \(app.name ?? bundleID)..."
                let accountID = EmberAccountManager.shared.accountID(for: bundleID)
                let identity = try await EmberAccountManager.shared.provisionSigningIdentity(bundleID: bundleID, accountID: accountID)
                let oldUUIDs = Set(signedApps().compactMap(\.uuid))
                try await sign(app, with: identity)
                guard let refreshed = signedApps().first(where: { $0.identifier == bundleID && !oldUUIDs.contains($0.uuid ?? "") }) else {
                    throw EmberError.message("The refreshed app was signed but not found in the library.")
                }
                try await install(refreshed)
            } catch {
                failures += 1
                EmberErrorCenter.shared.record(error, operation: "Auto refresh \(bundleID)")
            }
        }
        let watchResult = await EmberWatchRefreshManager.shared.refreshIfNeeded(force: force && EmberWatchRefreshManager.shared.enabled)
        if case .failed = watchResult { failures += 1 }
        lastRun = Date()
        UserDefaults.standard.set(lastRun, forKey: "EmberSign.lastRefresh")
        if failures > 0 {
            status = "Finished with \(failures) failure(s). Open Error diagnostics and Watch refresh status."
        } else if apps.isEmpty, case .skipped = watchResult {
            status = "No tracked apps need refresh."
        } else {
            status = "Refreshed \(apps.count) iPhone app(s)\(watchResult == .success ? " and the Apple Watch companion" : "")."
        }
        return failures == 0
    }

    private func signedApps() -> [Signed] {
        let request: NSFetchRequest<Signed> = Signed.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
        return (try? Storage.shared.context.fetch(request)) ?? []
    }

    private func sign(_ app: Signed, with certificate: CertificatePair) async throws {
        var options = Options.defaultOptions
        options.appIdentifier = app.identifier
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            FR.signPackageFile(app, using: options, icon: nil, certificate: certificate) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func install(_ app: Signed) async throws {
        let viewModel = InstallerStatusViewModel(isIdevice: true)
        let archive = ArchiveHandler(app: app, viewModel: viewModel)
        try await archive.move()
        let package = try await archive.archive()
        let installer = InstallationProxy(viewModel: viewModel)
        try await installer.install(at: package)
    }
}

struct EmberAutoRefreshView: View {
    @ObservedObject private var refresh = EmberAutoRefreshManager.shared

    var body: some View {
        List {
            Section {
                Toggle("Automatic re-sign and reinstall", isOn: Binding(get: { refresh.enabled }, set: { refresh.enabled = $0 }))
                Picker("Refresh when remaining", selection: Binding(get: { refresh.thresholdDays }, set: { refresh.thresholdDays = $0 })) {
                    Text("1 day").tag(1)
                    Text("2 days").tag(2)
                    Text("3 days").tag(3)
                }
                Button { Task { _ = await refresh.refreshAll(force: true) } } label: {
                    HStack { Label("Refresh tracked apps now", systemImage: "arrow.triangle.2.circlepath"); Spacer(); if refresh.isRunning { ProgressView() } }
                }.disabled(refresh.isRunning)
            } footer: {
                Text("A tracked app is one provisioned through an EmberSign Apple Account. The original signed app remains in EmberSign's library so it can be signed again. Background execution is controlled by iOS and succeeds only while the pairing tunnel is reachable. Open EmberSign periodically as a fallback.")
            }
            Section("Status") {
                if let lastRun = refresh.lastRun { LabeledContent("Last attempt", value: lastRun.formatted(date: .abbreviated, time: .shortened)) }
                Text(refresh.status).textSelection(.enabled)
            }
        }
        .navigationTitle("Auto refresh")
    }
}
