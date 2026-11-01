import Foundation
import SwiftUI
import CoreData
import IDeviceSwift
import UIKit
import UserNotifications

struct EmberRefreshEntry: Identifiable {
    let id: String
    let name: String
    let hasRecoveryProfiles: Bool
}

@MainActor
final class EmberAutoRefreshManager: ObservableObject {
    static let shared = EmberAutoRefreshManager()
    @Published var isRunning = false
    @Published var status = "Auto refresh runs when iOS gives EmberSign background time and the pairing tunnel is reachable."
    @Published var lastRun: Date? = UserDefaults.standard.object(forKey: "EmberSign.lastRefresh") as? Date
    @Published private(set) var reminderStatus = "Enable reminders to receive a notification before tracked app signing expires."

    var remindersEnabled: Bool {
        UserDefaults.standard.bool(forKey: "EmberSign.refreshReminders")
    }

    var reminderDays: Int {
        get { max(1, UserDefaults.standard.integer(forKey: "EmberSign.reminderDays") == 0 ? 2 : UserDefaults.standard.integer(forKey: "EmberSign.reminderDays")) }
        set {
            UserDefaults.standard.set(max(1, min(newValue, 3)), forKey: "EmberSign.reminderDays")
            objectWillChange.send()
            Task { await scheduleReminders() }
        }
    }

    func setReminders(_ enabled: Bool) async {
        if enabled {
            do {
                guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) else {
                    reminderStatus = "Notification permission was denied. Enable it in iOS Settings to receive reminders."
                    return
                }
            } catch {
                reminderStatus = "Could not request reminder permission: " + error.localizedDescription
                return
            }
        }
        UserDefaults.standard.set(enabled, forKey: "EmberSign.refreshReminders")
        objectWillChange.send()
        await scheduleReminders()
    }

    /// Notifications are scheduled from known certificate expiry dates. iOS may
    /// delay delivery; this never claims to extend an app's signing lifetime.
    func scheduleReminders() async {
        let center = UNUserNotificationCenter.current()
        let settings = UserDefaults.standard
        let oldIDs = settings.stringArray(forKey: "EmberSign.refreshReminderIDs") ?? []
        center.removePendingNotificationRequests(withIdentifiers: oldIDs)
        settings.set([String](), forKey: "EmberSign.refreshReminderIDs")
        guard remindersEnabled else {
            reminderStatus = "Refresh reminders are off."
            return
        }
        let authorization = await center.notificationSettings().authorizationStatus
        guard authorization == .authorized || authorization == .provisional else {
            reminderStatus = "Notifications are not authorized. Enable them in iOS Settings."
            return
        }
        let lead = TimeInterval(reminderDays) * 86_400
        var identifiers: [String] = []
        var seen = Set<String>()
        for app in signedApps() {
            guard let bundleID = app.identifier,
                  let accountID = EmberAccountManager.shared.accountID(for: bundleID),
                  let inventory = EmberAccountManager.shared.inventories[accountID],
                  seen.insert(bundleID).inserted,
                  let expiry = inventory.profiles
                    .filter({ $0.bundleIdentifier == bundleID })
                    .map(\.dateExpire).min() else { continue }
            let when = expiry.addingTimeInterval(-lead)
            guard when.timeIntervalSinceNow > 60, identifiers.count < 30 else { continue }
            let identifier = "EmberSign.refresh." + bundleID
            let content = UNMutableNotificationContent()
            content.title = "Refresh \(app.name ?? bundleID)"
            content.body = "Its development signing is due to expire in \(reminderDays) day(s). Open EmberSign to re-sign it."
            content.sound = .default
            let date = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: when)
            let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                identifiers.append(identifier)
            } catch {
                EmberErrorCenter.shared.record(error, operation: "Schedule refresh reminder")
            }
        }
        settings.set(identifiers, forKey: "EmberSign.refreshReminderIDs")
        reminderStatus = identifiers.isEmpty
            ? "No future profile expiry dates found. Refresh your Apple Account's provisioning profile list, then reschedule."
            : "Scheduled \(identifiers.count) reminder(s) from Apple provisioning profile expiry dates."
    }

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
        if remindersEnabled { Task { await scheduleReminders() } }
    }

    /// Only apps with a known EmberSign Apple Account can be refreshed here.
    /// A purchased/enterprise certificate is never silently replaced by a free account.
    func trackedApps() -> [EmberRefreshEntry] {
        var seen = Set<String>()
        // An unreadable recovery store is treated as protected, not empty.
        let suspended = try? EmberSlotStore.load()
        return signedApps().compactMap { app in
            guard let id = app.identifier, !id.isEmpty,
                  id != Bundle.main.bundleIdentifier,
                  EmberAccountManager.shared.accountID(for: id) != nil,
                  seen.insert(id).inserted else { return nil }
            return EmberRefreshEntry(id: id, name: app.name ?? id,
                                     hasRecoveryProfiles: suspended?.contains(where: { $0.id == id }) ?? true)
        }
    }

    func refresh(bundleID: String) async -> Bool {
        guard !isRunning else { return false }
        do {
            guard try !EmberSlotStore.hasSavedProfiles(for: bundleID) else {
                status = "Restore the saved provisioning profiles for \(bundleID) before re-signing. Refresh would reactivate the app and may consume a free-team slot."
                return false
            }
        } catch {
            status = "Refresh blocked: cannot read recovery profiles. " + error.localizedDescription
            return false
        }
        guard EmberAccountManager.shared.accountID(for: bundleID) != nil,
              let app = signedApps().first(where: { $0.identifier == bundleID }) else {
            status = "No signed IPA and Apple Account are recorded for \(bundleID). Import it before refreshing."
            return false
        }
        return await performRefresh([app], includeWatch: false)
    }

    func refreshAll(force: Bool = false) async -> Bool {
        guard !isRunning else { return false }
        let suspended: Set<String>
        do {
            suspended = Set(try EmberSlotStore.load().map(\.id))
        } catch {
            status = "Automatic refresh paused: cannot verify saved recovery profiles. " + error.localizedDescription
            return false
        }
        var seen = Set<String>()
        let apps: [Signed] = (enabled || force) ? signedApps().filter { app in
            guard let bundleID = app.identifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  !suspended.contains(bundleID),
                  EmberAccountManager.shared.accountID(for: bundleID) != nil,
                  seen.insert(bundleID).inserted else { return false }
            if force { return true }
            return EmberSigningExpiryPolicy.needsRefresh(
                inventoryProfile: profileExpiry(for: bundleID),
                storedProfile: Storage.shared.getCertificate(from: app)?.expiration,
                thresholdDays: thresholdDays
            )
        } : []

        return await performRefresh(apps, includeWatch: true, forceWatch: force)
    }

    private func performRefresh(_ apps: [Signed], includeWatch: Bool, forceWatch: Bool = false) async -> Bool {
        isRunning = true
        defer { isRunning = false }
        var failures = 0
        for app in apps {
            guard let bundleID = app.identifier else { continue }
            do {
                guard try !EmberSlotStore.hasSavedProfiles(for: bundleID) else {
                    throw EmberError.message("Recovery profiles exist. Reactivate this app before refreshing it.")
                }
                status = "Refreshing \(app.name ?? bundleID)..."
                let accountID = EmberAccountManager.shared.accountID(for: bundleID)
                let identity = try await EmberAccountManager.shared.provisionSigningIdentity(bundleID: bundleID, accountID: accountID)
                let oldUUIDs = Set(signedApps().compactMap(\.uuid))
                try await sign(app, with: identity)
                guard let refreshed = signedApps().first(where: { $0.identifier == bundleID && !oldUUIDs.contains($0.uuid ?? "") }) else {
                    throw EmberError.message("The refreshed app was signed but not found in the library.")
                }
                guard try !EmberSlotStore.hasSavedProfiles(for: bundleID) else {
                    throw EmberError.message("The app was deactivated during signing. Installation cancelled to preserve its free-team slot.")
                }
                try await install(refreshed)
            } catch {
                failures += 1
                EmberErrorCenter.shared.record(error, operation: "Auto refresh \(bundleID)")
            }
        }
        let watchResult: EmberWatchRefreshOutcome
        if includeWatch {
            watchResult = await EmberWatchRefreshManager.shared.refreshIfNeeded(force: forceWatch && EmberWatchRefreshManager.shared.enabled)
        } else {
            watchResult = .skipped
        }
        if case .failed = watchResult { failures += 1 }
        lastRun = Date()
        UserDefaults.standard.set(lastRun, forKey: "EmberSign.lastRefresh")
        if remindersEnabled { await scheduleReminders() }
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

    private func profileExpiry(for bundleID: String) -> Date? {
        guard let accountID = EmberAccountManager.shared.accountID(for: bundleID),
              let inventory = EmberAccountManager.shared.inventories[accountID] else { return nil }
        return inventory.profiles
            .filter { $0.bundleIdentifier == bundleID }
            .map(\.dateExpire).min()
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
            Section {
                Toggle("Remind me before signing expires", isOn: Binding(
                    get: { refresh.remindersEnabled },
                    set: { enabled in Task { await refresh.setReminders(enabled) } }
                ))
                if refresh.remindersEnabled {
                    Picker("Remind me", selection: Binding(get: { refresh.reminderDays }, set: { refresh.reminderDays = $0 })) {
                        Text("1 day before").tag(1)
                        Text("2 days before").tag(2)
                        Text("3 days before").tag(3)
                    }
                    Button("Reschedule reminders") { Task { await refresh.scheduleReminders() } }
                }
                Text(refresh.reminderStatus).font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Expiry notifications")
            } footer: {
                Text("Uses provisioning profile expiry dates from the Apple Account inventory. Refresh your account after re-signing. iOS controls delivery.")
            }
            Section("Tracked iPhone apps") {
                ForEach(refresh.trackedApps()) { app in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name)
                            Text(app.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                            if app.hasRecoveryProfiles {
                                Text("Recovery profiles saved. Reactivate before refresh.")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button("Refresh") { Task { _ = await refresh.refresh(bundleID: app.id) } }
                            .disabled(refresh.isRunning || app.hasRecoveryProfiles)
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .navigationTitle("Auto refresh")
    }
}
