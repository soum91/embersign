// This source is compiled into the MPL-2.0 StikJIT framework, not EmberSign.
// EmberSign controls a DIFFERENT app, so it does not need StikJIT's self-debug
// helper extension. StikJIT still owns DDI preparation and debugger attachment.
import Foundation
@_implementationOnly import idevice

public enum EmberTargetLauncher {
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

        var control: OpaquePointer?
        try IdeviceFFI.check("failed to open device ProcessControl") {
            process_control_new(remoteServer, &control)
        }
        guard let control else {
            throw StikJITError.deviceNotReady("Device ProcessControl did not start.")
        }
        defer { process_control_free(control) }

        var pid: UInt64 = 0
        try IdeviceFFI.check("failed to launch the selected application") {
            bundleID.withCString { id in
                process_control_launch_app(control, id, nil, 0, nil, 0,
                                           false, false, &pid)
            }
        }
        guard pid > 0, pid <= UInt64(Int32.max) else {
            throw StikJITError.deviceNotReady("The device returned an invalid app PID.")
        }
        return Int32(pid)
    }
}
