import Foundation
import SwiftUI

struct EmberErrorEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let operation: String
    let domain: String
    let code: Int
    let message: String

    var searchTerm: String {
        let embedded = message.matches(of: /-?\d{3,6}/).first.map { String($0.output) }
        return embedded ?? (code == 0 ? message : "\(domain) \(code)")
    }
}

@MainActor
final class EmberErrorCenter: ObservableObject {
    static let shared = EmberErrorCenter()
    @Published private(set) var entries: [EmberErrorEntry] = []
    private let key = "EmberSign.errorHistory"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([EmberErrorEntry].self, from: data) {
            entries = decoded
        }
    }

    func record(_ error: Error, operation: String) {
        let value = error as NSError
        entries.insert(EmberErrorEntry(
            id: UUID(), date: Date(), operation: operation,
            domain: value.domain, code: value.code,
            message: error.localizedDescription
        ), at: 0)
        entries = Array(entries.prefix(100))
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) }
    }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: key)
    }

    func advice(for entry: EmberErrorEntry) -> [String] {
        let text = "\(entry.code) \(entry.message)".lowercased()
        if text.contains("-80045") || text.contains("503") {
            return ["Apple or the Anisette service may be rejecting the current client identity.", "Retry later, then try a different trusted Anisette server. Do not repeatedly submit the password because Apple can rate-limit the account."]
        }
        if text.contains("-45061") || text.contains("device not provisioned") {
            return ["The Anisette device state is not provisioned.", "Remove the saved Anisette state, select a working server, and sign in again."]
        }
        if text.contains("3017") || text.contains("provisioning profile") {
            return ["The requested provisioning profile is missing, expired, or no longer matches the certificate/App ID.", "Refresh the account and create a fresh signing identity for the app."]
        }
        if text.contains("maximum app") || text.contains("app id limit") {
            return ["The Personal Team App ID quota is full.", "Remove an unused profile and App ID when Apple allows it, or wait for its seven-day registration window to expire."]
        }
        if text.contains("certificate") && (text.contains("maximum") || text.contains("too many")) {
            return ["The team has reached its development-certificate limit.", "Revoke only a certificate you recognize as unused. Revoking one can stop every app signed by it from launching."]
        }
        if text.contains("missing pairing") || text.contains("invalidhostid") || text.contains("tunnel") {
            return ["The device pairing tunnel is unavailable or the pairing file does not match this device.", "Connect LocalDevVPN, import a current pairing record, and retry the tunnel check."]
        }
        return ["Copy the full domain, code, and message before changing anything.", "Use the online results below to compare the exact code with current SideStore and AltStore reports."]
    }
}

struct EmberGitHubIssue: Decodable, Identifiable {
    let id: Int
    let title: String
    let html_url: URL
    let state: String
}

private struct EmberGitHubIssueResponse: Decodable { let items: [EmberGitHubIssue] }

@MainActor
final class EmberOnlineErrorLookup: ObservableObject {
    @Published var results: [EmberGitHubIssue] = []
    @Published var isLoading = false
    @Published var message = ""

    func search(_ term: String) async {
        isLoading = true
        message = ""
        defer { isLoading = false }
        var components = URLComponents(string: "https://api.github.com/search/issues")!
        components.queryItems = [URLQueryItem(name: "q", value: "repo:SideStore/SideStore \"\(term)\"")]
        do {
            var request = URLRequest(url: components.url!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("EmberSign/0.2", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            results = Array(try JSONDecoder().decode(EmberGitHubIssueResponse.self, from: data).items.prefix(10))
            message = results.isEmpty ? "No matching SideStore issues found." : "Found \(results.count) related reports."
        } catch {
            message = "Online lookup failed: \(error.localizedDescription)"
        }
    }
}

struct EmberErrorCenterView: View {
    @ObservedObject private var center = EmberErrorCenter.shared
    @StateObject private var lookup = EmberOnlineErrorLookup()
    @State private var selected: EmberErrorEntry?

    var body: some View {
        List {
            if center.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No recorded errors").font(.headline)
                    Text("Apple, signing, pairing, installation, and refresh failures will appear here with their complete domain and code.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ForEach(center.entries) { entry in
                    Button { selected = entry } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.operation).foregroundStyle(.primary)
                            Text("\(entry.domain) (\(entry.code))").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(entry.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
        .navigationTitle("Error diagnostics")
        .toolbar { if !center.entries.isEmpty { Button("Clear") { center.clear() } } }
        .sheet(item: $selected) { entry in
            NavigationStack {
                List {
                    Section("Error") {
                        LabeledContent("Operation", value: entry.operation)
                        LabeledContent("Domain", value: entry.domain)
                        LabeledContent("Code", value: String(entry.code))
                        Text(entry.message).textSelection(.enabled)
                    }
                    Section("Suggested checks") {
                        ForEach(center.advice(for: entry), id: \.self) { Text($0) }
                    }
                    Section("Current online reports") {
                        Button { Task { await lookup.search(entry.searchTerm) } } label: {
                            HStack { Label("Find fixes online", systemImage: "magnifyingglass"); Spacer(); if lookup.isLoading { ProgressView() } }
                        }.disabled(lookup.isLoading)
                        if !lookup.message.isEmpty { Text(lookup.message).font(.footnote).foregroundStyle(.secondary) }
                        ForEach(lookup.results) { issue in
                            Link(destination: issue.html_url) {
                                VStack(alignment: .leading) {
                                    Text(issue.title)
                                    Text(issue.state.capitalized).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let query = entry.searchTerm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                           let url = URL(string: "https://www.google.com/search?q=Apple+sideloading+\(query)") {
                            Link("Search the wider web", destination: url)
                        }
                    }
                }
                .navigationTitle("Error details")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { selected = nil } } }
            }
        }
    }
}
