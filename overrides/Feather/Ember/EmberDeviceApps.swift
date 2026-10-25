import Foundation
import SwiftUI
import IDeviceSwift

@MainActor
final class EmberDeviceAppsModel: NSObject, ObservableObject, InstallationProxyAppsDelegate {
    @Published var apps: [AppInfo] = []
    @Published var isLoading = false
    @Published var status = "Connect LocalDevVPN and import this device's pairing file to scan installed apps."
    private let proxy = InstallationAppProxy()

    override init() {
        super.init()
        proxy.delegate = self
    }

    nonisolated func updateApplications(with apps: [AppInfo]) {
        Task { @MainActor [weak self] in
            self?.apps = apps.sorted {
                ($0.CFBundleDisplayName ?? $0.CFBundleName ?? $0.CFBundleIdentifier ?? "")
                    .localizedCaseInsensitiveCompare($1.CFBundleDisplayName ?? $1.CFBundleName ?? $1.CFBundleIdentifier ?? "") == .orderedAscending
            }
            self?.isLoading = false
            self?.status = "Found \(apps.count) apps through the paired-device service."
        }
    }

    func scan() async {
        isLoading = true
        status = "Reading installed app metadata..."
        do {
            try await proxy.listApps()
        } catch {
            isLoading = false
            status = error.localizedDescription
            EmberErrorCenter.shared.record(error, operation: "Scan installed apps")
        }
    }

    func uninstall(_ app: AppInfo, removePortalRecords: Bool) async {
        guard let bundleID = app.CFBundleIdentifier else { return }
        isLoading = true
        do {
            try await InstallationAppProxy.deleteApp(for: bundleID)
            if removePortalRecords {
                try await EmberAccountManager.shared.revokePortalRecords(bundleID: bundleID, teamID: app.teamIdentifier)
            }
            status = removePortalRecords
                ? "Uninstalled \(app.displayName) and requested removal of its provisioning profile/App ID."
                : "Uninstalled \(app.displayName)."
            try await proxy.listApps()
        } catch {
            isLoading = false
            status = error.localizedDescription
            EmberErrorCenter.shared.record(error, operation: removePortalRecords ? "Uninstall and revoke app" : "Uninstall app")
        }
    }
}

private extension AppInfo {
    var displayName: String { CFBundleDisplayName ?? CFBundleName ?? CFBundleIdentifier ?? "Unknown" }
    var teamIdentifier: String? {
        if let value = Entitlements?["com.apple.developer.team-identifier"]?.value as? String { return value }
        if let value = Entitlements?["application-identifier"]?.value as? String { return value.split(separator: ".").first.map(String.init) }
        return nil
    }
    var applicationIdentifier: String? { Entitlements?["application-identifier"]?.value as? String }
    var getTaskAllow: Bool? { Entitlements?["get-task-allow"]?.value as? Bool }
}

struct EmberDeviceAppsView: View {
    @StateObject private var model = EmberDeviceAppsModel()
    @ObservedObject private var accounts = EmberAccountManager.shared
    @State private var selected: AppInfo?
    @State private var pendingRemoval: AppInfo?

    var body: some View {
        List {
            Section {
                Button { Task { await model.scan() } } label: {
                    HStack { Label("Scan device", systemImage: "arrow.clockwise"); Spacer(); if model.isLoading { ProgressView() } }
                }.disabled(model.isLoading)
                Text(model.status).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            } footer: {
                Text("The list comes from Apple's paired-device installation service, not from private app folders. A working pairing tunnel is required.")
            }
            ForEach(model.apps) { app in
                Button { selected = app } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.displayName).foregroundStyle(.primary)
                        Text(app.CFBundleIdentifier ?? "Unknown bundle ID").font(.caption.monospaced()).foregroundStyle(.secondary)
                        HStack {
                            Text("v\(app.CFBundleShortVersionString ?? "?") (\(app.CFBundleVersion ?? "?"))")
                            if let team = app.teamIdentifier {
                                Text("•")
                                Text(accounts.account(forTeamID: team)?.auth.account.appleID ?? team)
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { pendingRemoval = app } label: { Label("Remove", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("Installed apps")
        .task { await model.scan() }
        .sheet(item: $selected) { app in
            NavigationStack {
                List {
                    Section("Application") {
                        LabeledContent("Name", value: app.displayName)
                        LabeledContent("Bundle ID", value: app.CFBundleIdentifier ?? "Unknown")
                        LabeledContent("Version", value: app.CFBundleShortVersionString ?? "Unknown")
                        LabeledContent("Build", value: app.CFBundleVersion ?? "Unknown")
                        LabeledContent("Minimum iOS", value: app.MinimumOSVersion ?? "Unknown")
                    }
                    Section("Signing") {
                        LabeledContent("Signer", value: app.SignerIdentity ?? "Unknown")
                        LabeledContent("Team ID", value: app.teamIdentifier ?? "Unknown")
                        LabeledContent("Account", value: accounts.account(forTeamID: app.teamIdentifier)?.auth.account.appleID ?? "Not matched")
                        LabeledContent("Application ID", value: app.applicationIdentifier ?? "Unknown")
                        LabeledContent("JIT entitlement", value: app.getTaskAllow == true ? "Enabled" : "Not enabled")
                    }
                    Section {
                        Button(role: .destructive) { pendingRemoval = app; selected = nil } label: { Label("Uninstall or revoke", systemImage: "trash") }
                    } footer: {
                        Text("Removing the portal App ID does not guarantee immediate quota recovery. Apple controls the Personal Team seven-day registration window.")
                    }
                }
                .navigationTitle(app.displayName)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { selected = nil } } }
            }
        }
        .confirmationDialog("Remove \(pendingRemoval?.displayName ?? "app")?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible) {
            if let app = pendingRemoval {
                Button("Uninstall only", role: .destructive) {
                    pendingRemoval = nil
                    Task { await model.uninstall(app, removePortalRecords: false) }
                }
                Button("Uninstall and remove signing records", role: .destructive) {
                    pendingRemoval = nil
                    Task { await model.uninstall(app, removePortalRecords: true) }
                }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        }
    }
}
