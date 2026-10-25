import SwiftUI

/// EmberSign's About screen. Feather's original attribution remains visible below.
struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    FRAppIconView(size: 76)
                    Text("EmberSign")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.orange)
                    Text("Version \(version)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Sign, refresh, and manage apps on your device.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }

            Section("Project") {
                Link("EmberSign source and releases", destination: URL(string: "https://github.com/soum91/embersign")!)
                Text("EmberSign adds Apple Account management, pairing, JIT controls, refresh, and diagnostics to the open-source Feather app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Open-source credits") {
                Link("Feather by Samara M (C) and contributors", destination: URL(string: "https://github.com/claration/feather")!)
                Link("Asami (Feather contributor)", destination: URL(string: "https://github.com/Nyasami")!)
                Link("Lakhan Lothiyi (AltStore repositories)", destination: URL(string: "https://github.com/llsc12")!)
                Link("SideSign by the SideStore contributors", destination: URL(string: "https://github.com/SideStore/SideSign")!)
                Text("EmberSign is an independent Feather derivative, not an official Feather, SideStore, or Apple product. Original and third-party licenses are included with the source distribution.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About EmberSign")
    }
}
