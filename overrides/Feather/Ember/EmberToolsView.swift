import SwiftUI
import UIKit
import UniformTypeIdentifiers
import IDeviceSwift

struct EmberToolsView: View {
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
                Section("Device tools") {
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
                    Text("Import an IPA in Apps, tap Sign, then open Tweaks to add compatible libraries or Debian packages before signing.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Compatibility") {
                    Text("JIT preparation requires a development provisioning profile. Activation uses StikDebug on supported devices or your own SideJITServer. Newer iOS versions can require app-specific JIT support.")
                    Text("An exported pairing file is a copy of your imported record. Initial pairing normally uses a trusted computer. Lockdown and remote-pairing files are different formats; the receiving app must support the format you export.")
                    Text("Tweaks run inside the signed app. Tweaks that depend on jailbreak services or system-wide hooks will not work.")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("EmberSign")
        }
    }
}

struct EmberPairingView: View {
    @State private var record: EmberPairingRecord?
    @State private var importing = false
    @State private var exporting = false
    @State private var removing = false
    @State private var document: EmberPairingDocument?
    @State private var message: String?
    @State private var checking = false

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
                Text("Pair your phone using iLoader or another trusted pairing tool on your computer. Import the resulting .mobiledevicepairing or .plist file here. EmberSign cannot extract credentials from another app's private storage.")
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
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .emberPairingChanged)) { _ in reload() }
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
            Section("On this device") {
                Button { Task { await jit.openStikDebug() } } label: {
                    Label("Enable with StikDebug", systemImage: "bolt.fill")
                }.disabled(jit.bundleID.isEmpty)
                Link("Get StikDebug", destination: URL(string: "https://github.com/StikDebug/StikDebug/releases")!)
                Button {
                    UIApplication.shared.open(URL(string: "localdevvpn://enable?scheme=embersign")!)
                } label: { Label("Connect LocalDevVPN", systemImage: "network") }
            } footer: {
                Text("Import your exported pairing file into StikDebug and complete its developer-image setup. A pairing file alone does not grant JIT. On newer iOS versions, the target app may need its own compatible JIT implementation.")
            }
            Section("SideJITServer fallback") {
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
