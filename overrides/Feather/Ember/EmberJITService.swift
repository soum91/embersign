import Foundation
import UIKit
import Combine

@MainActor
final class EmberJITService: ObservableObject {
    static let shared = EmberJITService()
    @Published var bundleID = ""
    @Published var isBusy = false
    @Published var status = "Choose a signed app or enter its installed bundle identifier."
    @Published var devices: [String: String] = [:]
    @Published var history: [String] = []
    @Published var showAppSheet = false

    func present(bundleID: String) {
        self.bundleID = bundleID
        showAppSheet = true
    }

    func record(_ message: String) {
        status = message
        history.insert(message, at: 0)
        if history.count > 40 { history.removeLast(history.count - 40) }
    }

    func openStikDebug() async {
        do {
            let url = try EmberJITProtocol.stikURL(bundleID: bundleID)
            guard UIApplication.shared.canOpenURL(url) else {
                throw EmberError.message("Install StikDebug, import your pairing file there, and connect LocalDevVPN before activating JIT.")
            }
            let opened = await UIApplication.shared.open(url)
            guard opened else { throw EmberError.message("iOS could not open StikDebug.") }
            record("Activation handed to StikDebug. Check its result there; opening the app does not confirm JIT is active.")
        } catch { record(error.localizedDescription) }
    }

    func discover(base: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let versionData = try await request(EmberJITProtocol.serverURL(base: base, components: ["ver"]))
            guard let version = try JSONSerialization.jsonObject(with: versionData) as? [String: Any],
                  version["SideJITServer"] != nil else {
                throw EmberError.message("This address did not identify itself as SideJITServer.")
            }
            let data = try await request(EmberJITProtocol.serverURL(base: base, components: []))
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                throw EmberError.message("The server returned an invalid device list.")
            }
            if let error = result["ERROR"] { throw EmberError.message(error) }
            devices = result
            record(result.isEmpty ? "The server found no paired devices." : "Connected. Choose your device below.")
        } catch { record(error.localizedDescription) }
    }

    func enableOnServer(base: String, udid: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard !bundleID.isEmpty, !udid.isEmpty else {
                throw EmberError.message("Enter the installed bundle identifier and select your device.")
            }
            let url = try EmberJITProtocol.serverURL(base: base, components: [udid, bundleID])
            let data = try await request(url)
            _ = try EmberJITProtocol.activationMessage(data: data)
            record("SideJITServer reported JIT enabled. The target app must confirm its runtime state.")
        } catch { record(error.localizedDescription) }
    }

    private func request(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = "GET"
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw EmberError.message("The JIT server rejected the request. Check that this device is paired and the app is installed with debugger permission.")
        }
        return data
    }
}
