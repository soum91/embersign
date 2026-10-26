import Foundation
import UIKit
import Combine
import StikJIT

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

    var builtInSupported: Bool {
        if #available(iOS 17.4, *) { return true }
        return false
    }

    /// Enable JIT in another app. EmberSign is the debugger process, so the
    /// StikJIT self-debug helper extension is unnecessary here.
    func enableBuiltIn() async {
        guard !isBusy else { return }
        guard #available(iOS 17.4, *) else {
            record("Built-in JIT requires iOS 17.4 or newer.")
            return
        }
        let target = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target != Bundle.main.bundleIdentifier else {
            record("Select another sideloaded app. EmberSign cannot attach to itself.")
            return
        }
        let credentials: EmberPairingRecord
        do {
            credentials = try EmberPairingStore.read()
            guard credentials.kind == .remote else {
                throw EmberError.message("Built-in StikJIT requires remote pairing credentials. Generate remote pairing in Tools > Pairing file or import a compatible record.")
            }
        } catch { record(error.localizedDescription); return }

        isBusy = true
        record("Preparing built-in StikJIT for \(target). Connect LocalDevVPN first.")
        let pairURL = EmberPairingStore.url
        let outcome = await Task.detached(priority: .userInitiated) { [weak self] () -> Result<String, Error> in
            do {
                let root = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("EmberSign/StikJIT", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let paths = DDIPaths.default(in: root)
                let readiness = StikJIT.prepareDevice(pairingFile: pairURL, paths: paths) { stage in
                    let message: String
                    switch stage {
                    case .checkingReachability: message = "Checking the local device tunnel…"
                    case .checkingDDI: message = "Checking Developer Disk Image…"
                    case .downloadingDDI(let fraction, let details):
                        message = "Downloading developer image \(Int(fraction * 100))%: \(details)"
                    case .mountingDDI(let fraction): message = "Mounting developer image \(Int(fraction * 100))%"
                    case .verifyingDDI: message = "Verifying developer image…"
                    case .ready: message = "Device prepared for JIT."
                    }
                    Task { @MainActor [weak self] in self?.record(message) }
                }
                switch readiness {
                case .ready: break
                case .unreachable(let reason): throw EmberError.message("Device tunnel unavailable: \(reason). Connect LocalDevVPN and use Wi-Fi.")
                case .preparationFailed(let reason): throw EmberError.message("Developer image setup failed: \(reason)")
                }

                let pid = try EmberTargetLauncher.launch(bundleID: target, pairingFile: pairURL)
                Task { @MainActor [weak self] in self?.record("Device launched \(target) (PID \(pid)). Attaching debugger…") }
                try StikJIT.enableJIT(targetPID: pid, pairingFile: pairURL, ddiPaths: paths,
                                     script: .universal) { stage in
                    if case .ready = stage { return }
                } progress: { message in
                    Task { @MainActor [weak self] in self?.record(message) }
                }
                return .success("StikJIT completed debugger activation for \(target) (PID \(pid)). The app must confirm JIT availability; iOS 26+ targets need compatible JIT memory handling.")
            } catch { return .failure(error) }
        }.value
        isBusy = false
        switch outcome {
        case .success(let message): record(message)
        case .failure(let error): record("Built-in JIT failed: \(error.localizedDescription)")
        }
    }

    func resetBuiltInDDI() async {
        guard #available(iOS 17.4, *), !isBusy else { return }
        isBusy = true
        let outcome = await Task.detached { () -> Result<String, Error> in
            do {
                let root = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("EmberSign/StikJIT", isDirectory: true)
                try StikJIT.resetCachedDDI(at: DDIPaths.default(in: root))
                return .success("Developer image cache cleared. It will download again when JIT is enabled.")
            } catch { return .failure(error) }
        }.value
        isBusy = false
        switch outcome {
        case .success(let message): record(message)
        case .failure(let error): record(error.localizedDescription)
        }
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
