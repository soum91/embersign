// This source is compiled into the MPL-2.0 StikJIT framework, not EmberSign.
// EmberSign controls a DIFFERENT app, so it does not need StikJIT's self-debug
// helper extension. StikJIT still owns DDI preparation and debugger attachment.
import Foundation
@_implementationOnly import idevice

public enum EmberTargetLauncher {
    private struct InstalledTarget {
        let bundleID: String
        let containerPath: String
    }

    /// Signing tools sometimes append a suffix to an app's original bundle ID.
    /// Resolve the identifier against what the device actually has installed,
    /// but never guess if more than one installed app matches that prefix.
    private static func installedTarget(_ requested: String, service: OpaquePointer) throws -> InstalledTarget {
        var entries: UnsafeMutablePointer<AppListEntryC>?
        var count: UInt = 0
        try IdeviceFFI.check("failed to read installed bundle identifiers") {
            app_service_list_apps(service, 1, 1, 1, 0, 0, &entries, &count)
        }
        defer { if let entries { app_service_free_app_list(entries, count) } }
        let apps: [InstalledTarget] = (0..<Int(count)).compactMap { index in
            guard let entry = entries?[index], let id = entry.bundle_identifier,
                  let path = entry.path else { return nil }
            return InstalledTarget(bundleID: String(cString: id), containerPath: String(cString: path))
        }
        if let exact = apps.first(where: { $0.bundleID == requested }) { return exact }
        let possible = apps.filter {
            $0.bundleID.hasPrefix(requested + ".") ||
            $0.bundleID.caseInsensitiveCompare(requested) == .orderedSame
        }
        if possible.count == 1, let match = possible.first { return match }
        if possible.count > 1 {
            throw StikJITError.deviceNotReady("Multiple installed apps match \(requested). Enter the full identifier from Settings > Installed apps.")
        }
        throw StikJITError.deviceNotReady("Cannot find \(requested) on this device. In EmberSign, open Settings > Installed apps, scan, and copy the installed bundle ID (including any signing suffix).")
    }

    private static func normalizedPath(_ value: String) -> String {
        if let url = URL(string: value), url.isFileURL { return url.path }
        return value.removingPercentEncoding ?? value
    }

    /// ProcessControl's launch reply can omit a numeric PID on some iOS builds.
    /// The device's AppService process inventory provides a separate, trusted PID.
    private static func runningPID(for target: InstalledTarget, service: OpaquePointer) throws -> Int32? {
        var processes: UnsafeMutablePointer<ProcessTokenC>?
        var count: UInt = 0
        try IdeviceFFI.check("failed to read running application processes") {
            app_service_list_processes(service, &processes, &count)
        }
        defer { if let processes { app_service_free_process_list(processes, count) } }
        let appPath = normalizedPath(target.containerPath).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !appPath.isEmpty else { return nil }
        for index in 0..<Int(count) {
            guard let process = processes?[index], process.pid > 0,
                  process.pid <= UInt32(Int32.max),
                  let executableURL = process.executable_url else { continue }
            let executable = normalizedPath(String(cString: executableURL))
            if executable.contains("/" + appPath + "/") ||
               executable.hasPrefix(appPath + "/") {
                return Int32(process.pid)
            }
        }
        return nil
    }

    /// Ask iOS ProcessControl to launch (or resume) a bundle ID and return its PID.
    /// Never force-kill an already running target. The PID comes from the remote
    /// device service rather than an untrusted process name or private sysctl.
    public static func launch(bundleID: String,
                              pairingFile: URL,
                              configuration: StikJIT.Configuration = .default) throws -> Int32 {
        guard !bundleID.isEmpty, !bundleID.contains("\u{0}") else {
            throw StikJITError.deviceNotReady("Enter an installed app bundle identifier.")
        }
        var pairing: OpaquePointer?
        try IdeviceFFI.check("failed to open pairing credentials") {
            pairingFile.path.withCString { rp_pairing_file_read($0, &pairing) }
        }
        guard let pairing else {
            throw StikJITError.deviceNotReady("Remote-pairing credentials are missing.")
        }
        defer { rp_pairing_file_free(pairing) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = configuration.rsdPort.bigEndian
        guard configuration.deviceAddress.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw StikJITError.deviceNotReady("Invalid LocalDevVPN endpoint address.")
        }

        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        try IdeviceFFI.check("failed to establish a trusted RSD tunnel") {
            "EmberSign".withCString { hostname in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socket in
                        tunnel_create_rppairing(socket, socklen_t(MemoryLayout<sockaddr_in>.stride),
                                                hostname, pairing, nil, nil, &adapter, &handshake)
                    }
                }
            }
        }
        defer {
            if let handshake { rsd_handshake_free(handshake) }
            if let adapter { adapter_free(adapter) }
        }

        var remoteServer: OpaquePointer?
        try IdeviceFFI.check("failed to connect device process services") {
            remote_server_connect_rsd(adapter, handshake, &remoteServer)
        }
        guard let remoteServer else {
            throw StikJITError.deviceNotReady("Device process services are unavailable.")
        }
        defer { remote_server_free(remoteServer) }

        var appService: OpaquePointer?
        try IdeviceFFI.check("failed to connect device application services") {
            app_service_connect_rsd(adapter, handshake, &appService)
        }
        guard let appService else {
            throw StikJITError.deviceNotReady("Device application inventory is unavailable.")
        }
        defer { app_service_free(appService) }

        let target = try installedTarget(bundleID, service: appService)
        // Attach to an already running instance without destroying its state.
        if let existing = try runningPID(for: target, service: appService) { return existing }

        var control: OpaquePointer?
        try IdeviceFFI.check("failed to open device ProcessControl") {
            process_control_new(remoteServer, &control)
        }
        guard let control else {
            throw StikJITError.deviceNotReady("Device ProcessControl did not start.")
        }
        defer { process_control_free(control) }

        var pid: UInt64 = 0
        var launchIssue: String?
        do {
            try IdeviceFFI.check("failed to launch the selected application") {
                target.bundleID.withCString { id in
                    process_control_launch_app(control, id, nil, 0, nil, 0,
                                               false, false, &pid)
                }
            }
        } catch {
            launchIssue = error.localizedDescription
        }
        if pid > 0, pid <= UInt64(Int32.max) { return Int32(pid) }

        // The launch can succeed even though CoreDevice supplies no numeric PID.
        // Give the process list a short window to reflect the new process.
        for _ in 0..<6 {
            if let running = try? runningPID(for: target, service: appService) {
                return running
            }
            usleep(350_000)
        }
        throw StikJITError.deviceNotReady("The selected app did not return a usable PID. Check its exact installed bundle ID and launch it once. \(launchIssue ?? "No running process matched the installed app container.")")
    }
}
