import SwiftUI
import UIKit
import UniformTypeIdentifiers
import IDeviceSwift

struct EmberToolsView: View {
    @ObservedObject private var accounts = EmberAccountManager.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 36)).foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("EmberSign").font(.title2.bold())
                            Text("Sign. Customize. Run.").foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 10)
                }
                Section("Apple signing") {
                    NavigationLink { EmberAccountsView() } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(accounts.accounts.isEmpty ? "Add Apple Account" : "Manage Apple Accounts", systemImage: "person.crop.circle.badge.checkmark")
                            Text(accounts.accounts.isEmpty
                                 ? "Sign in, complete 2FA, and provision apps."
                                 : "\(accounts.accounts.count) saved • \(accounts.selectedAccount?.auth.account.appleID ?? "Choose an account") selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Accounts stay separate in the device Keychain. See each account for its registered App IDs and estimated available slots.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Device tools") {
                    NavigationLink { EmberDeviceAppsView() } label: {
                        Label("Installed apps", systemImage: "square.grid.2x2")
                    }
                    NavigationLink { EmberAutoRefreshView() } label: {
                        Label("Auto refresh", systemImage: "arrow.triangle.2.circlepath")
                    }
                    NavigationLink { EmberPairingView() } label: {
                        Label("Pairing file", systemImage: "iphone.and.arrow.forward")
                    }
                    NavigationLink { EmberJITView() } label: {
                        Label("JIT", systemImage: "bolt.fill")
                    }
                }
                Section("Signing and tweaks") {
                    NavigationLink { CertificatesView() } label: {
                        Label("Signing certificates", systemImage: "checkmark.seal")
                    }
                    NavigationLink { ConfigurationView() } label: {
                        Label("Default signing options", systemImage: "signature")
                    }
                    NavigationLink { EmberErrorCenterView() } label: {
                        Label("Error diagnostics", systemImage: "stethoscope")
                    }
                    Text("Import an IPA in Apps, tap Sign, then open Tweaks to add compatible libraries or Debian packages before signing.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Compatibility") {
                    Text("Apple Account provisioning uses SideSign and Anisette. Passwords are never saved. Sessions and generated keys stay in this device's Keychain.")
                    Text("JIT preparation requires a development provisioning profile. Activation uses StikDebug on supported devices or your own SideJITServer. Newer iOS versions can require app-specific JIT support.")
                    Text("On iOS 27, you can generate a remote-pairing file in EmberSign through Developer Mode. Other versions generally require a trusted computer for the first pairing. Lockdown and remote pairing are distinct formats.")
                    Text("Tweaks run inside the signed app. Tweaks that depend on jailbreak services or system-wide hooks will not work.")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("EmberSign")
        }
    }
}

struct EmberPairingView: View {
    @ObservedObject private var selfPairing = EmberOnDevicePairing.shared
    @State private var record: EmberPairingRecord?
    @State private var importing = false
    @State private var exporting = false
    @State private var removing = false
    @State private var document: EmberPairingDocument?
    @State private var message: String?
    @State private var checking = false
    @State private var confirmReplace = false

    var body: some View {
        List {
            Section("Pairing record") {
                Label(record == nil ? "No pairing file" : "Pairing file imported",
                      systemImage: record == nil ? "link.badge.plus" : "checkmark.circle")
                if let record {
                    LabeledContent("Format", value: record.kind.rawValue)
                    Text("File structure checked. Device trust is confirmed only by a successful connection.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Generate on this iPhone") {
                if EmberOnDevicePairing.supported {
                    Button {
                        if record == nil { selfPairing.start() }
                        else { confirmReplace = true }
                    } label: {
                        Label("Start on-device pairing", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    }.disabled(selfPairing.active)

                    switch selfPairing.phase {
                    case .idle:
                        Text("Works on iOS 27. You will approve a new remote pairing in iPhone Settings.")
                            .foregroundStyle(.secondary)
                    case .waiting:
                        HStack {
                            ProgressView()
                            Text("Waiting for Developer Mode pairing…")
                        }
                    case .enterPIN(let code):
                        LabeledContent("Pairing code", value: code)
                            .font(.headline.monospacedDigit())
                        Text("Enter this code on the same iPhone in Developer Mode Settings.")
                    case .paired(let name):
                        Label("Paired with \(name). You can export the new record.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    case .failed(let reason):
                        Text(reason).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if selfPairing.active {
                        Button("Cancel pairing", role: .cancel) { selfPairing.stop() }
                    }
                    if selfPairing.limitedBackgroundTime && selfPairing.active {
                        Text("iOS did not allow extended background processing. Open Developer Mode promptly; pairing may stop when EmberSign is suspended.")
                            .foregroundStyle(.orange)
                    }
                    Text("After Start, open Settings > Privacy & Security > Developer Mode > Pair with EmberSign. Enter the six-digit code in EmberSign's notification or background task banner. Return here to export the saved remote pairing file.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("On-device pairing requires iOS 27 or newer. On this iOS version, create the initial pairing file with iLoader or another trusted computer tool and import it below.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button { importing = true } label: { Label("Import pairing file", systemImage: "square.and.arrow.down") }
                Button {
                    do {
                        let latest = try EmberPairingStore.read()
                        record = latest
                        document = EmberPairingDocument(data: latest.data)
                        exporting = true
                    } catch { message = error.localizedDescription }
                } label: { Label("Export to Files", systemImage: "square.and.arrow.up") }
                .disabled(record == nil)
                Button { checkConnection() } label: {
                    HStack {
                        Label("Check local tunnel", systemImage: "network")
                        if checking { Spacer(); ProgressView() }
                    }
                }.disabled(checking || record == nil || record?.kind == .remote)
                Button(role: .destructive) { removing = true } label: {
                    Label("Remove pairing file", systemImage: "trash")
                }.disabled(record == nil)
            } footer: {
                Text("Export to Files, then import that file in Reynard or another compatible app. The record contains private device-trust credentials; share it only with apps you trust. The socket check applies to Lockdown tunnels; validate remote pairing in your JIT tool.")
            }
            Section("First-time setup") {
                Text("On iOS versions before 27, pair using iLoader or another trusted computer tool. Import its .mobiledevicepairing or .plist file here. EmberSign cannot extract another app's private pairing credentials.")
                Link("Open pairing setup guide", destination: URL(string: "https://docs.sidestore.io/docs/advanced/pairing-file")!)
            }.font(.footnote)
            if let message { Section("Result") { Text(message).textSelection(.enabled) } }
        }
        .navigationTitle("Pairing file")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .propertyList], allowsMultipleSelection: false) { result in
            do {
                guard let source = try result.get().first else { return }
                try EmberPairingStore.importFile(source)
                reload()
                message = "Pairing file imported. You can now export a copy or check your tunnel."
            } catch { message = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .data,
                      defaultFilename: record?.exportName ?? "EmberSign.plist") { result in
            switch result {
            case .success: message = "Pairing file exported."
            case .failure(let error): message = error.localizedDescription
            }
            document = nil
        }
        .confirmationDialog("Remove the saved pairing file?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                do {
                    try EmberPairingStore.remove()
                    reload()
                    message = "Saved file removed. Reopen EmberSign to clear any in-memory tunnel session."
                } catch { message = error.localizedDescription }
            }
        }
        .confirmationDialog("Replace the saved pairing file?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Start new pairing") { selfPairing.start() }
        } message: {
            Text("A newly paired host can replace an older remote trust record. EmberSign preserves your current file until the new pairing succeeds, but the old remote pairing may then stop working.")
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .emberPairingChanged)) { _ in reload() }
        .onReceive(selfPairing.$phase) { phase in
            if case .paired = phase { reload() }
        }
    }

    private func reload() { record = try? EmberPairingStore.read() }

    private func checkConnection() {
        checking = true
        Task {
            let result = await Task.detached {
                HeartbeatManager.shared.checkSocketConnection(timeoutInSeconds: 3)
            }.value
            checking = false
            message = result.isConnected
                ? "Local tunnel socket is reachable. This does not yet verify pairing trust or JIT."
                : "Local tunnel unavailable. Connect LocalDevVPN and retry on Wi-Fi."
        }
    }
}

struct EmberJITView: View {
    @ObservedObject private var jit = EmberJITService.shared
    @AppStorage("EmberSign.jit.server") private var server = ""
    @AppStorage("EmberSign.jit.device") private var device = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section("Target app") {
                TextField("Installed bundle identifier", text: $jit.bundleID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("You can also hold a signed app in Apps and choose Enable JIT. Use the installed bundle identifier after any signing changes.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button { Task { await jit.openStikDebug() } } label: {
                    Label("Enable with StikDebug", systemImage: "bolt.fill")
                }.disabled(jit.bundleID.isEmpty)
                Link("Get StikDebug", destination: URL(string: "https://github.com/StikDebug/StikDebug/releases")!)
                Button {
                    UIApplication.shared.open(URL(string: "localdevvpn://enable?scheme=embersign")!)
                } label: { Label("Connect LocalDevVPN", systemImage: "network") }
            } header: {
                Text("On this device")
            } footer: {
                Text("Import your exported pairing file into StikDebug and complete its developer-image setup. A pairing file alone does not grant JIT. On newer iOS versions, the target app may need its own compatible JIT implementation.")
            }
            Section {
                TextField("http://computer-address:8080", text: $server)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Connect and find devices") { Task { await jit.discover(base: server) } }
                    .disabled(jit.isBusy || server.isEmpty)
                if !jit.devices.isEmpty {
                    Picker("Device", selection: $device) {
                        Text("Select your device").tag("")
                        ForEach(jit.devices.keys.sorted(), id: \.self) { name in
                            Text(name).tag(jit.devices[name] ?? "")
                        }
                    }
                }
                TextField("Device UDID", text: $device)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Request JIT from server") {
                    Task { await jit.enableOnServer(base: server, udid: device) }
                }.disabled(jit.isBusy || jit.bundleID.isEmpty || server.isEmpty || device.isEmpty)
            } header: {
                Text("SideJITServer fallback")
            } footer: {
                Text("Run SideJITServer on your trusted computer. EmberSign sends the selected device and app identifiers to the address you enter. Pairing files and signing keys are never uploaded by this feature.")
            }
            Section("Status") {
                if jit.isBusy { ProgressView("Contacting JIT server…") }
                Text(jit.status).textSelection(.enabled)
            }
            if !jit.history.isEmpty {
                Section("Session log") {
                    ForEach(Array(jit.history.enumerated()), id: \.offset) { entry in
                        Text(entry.element).font(.caption).textSelection(.enabled)
                    }
                    Button("Clear log") { jit.history.removeAll() }
                }
            }
        }
        .navigationTitle("JIT")
    }
}
