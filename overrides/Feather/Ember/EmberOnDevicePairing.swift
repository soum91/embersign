import Foundation
import UIKit
import Combine
import BackgroundTasks
import UserNotifications
import dnssd
import EmberPairingNative

/// A temporary, user-approved remote-pairing host on the iPhone itself.
/// This uses iOS 27's Settings-initiated pairing and is not a way to
/// extract a device's existing Lockdown keys.
@MainActor
final class EmberOnDevicePairing: ObservableObject {
    static let shared = EmberOnDevicePairing()

    enum Phase: Equatable {
        case idle
        case waiting
        case enterPIN(String)
        case paired(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var limitedBackgroundTime = false

    static var supported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        )
    }

    var active: Bool {
        switch phase {
        case .waiting, .enterPIN: return true
        default: return false
        }
    }

    private var handle: OpaquePointer?
    private var advertisement: DNSServiceRef?
    private var expiry: Timer?
    private var graceTask: UIBackgroundTaskIdentifier = .invalid
    private var continuousTask: AnyObject?
    private var registeredTaskID: String?

    private init() {}

    func start() {
        guard Self.supported else {
            phase = .failed("Generate pairing on iPhone requires iOS 27 or later. Import a file made on a trusted computer on older iOS.")
            return
        }
        guard !active && handle == nil else { return }

        var error: UnsafeMutablePointer<CChar>?
        guard let created = "EmberSign".withCString({ embersign_pair_start($0, &error) }) else {
            phase = .failed(Self.consume(error) ?? "Could not start the on-device pairing service.")
            return
        }
        handle = created
        phase = .waiting
        limitedBackgroundTime = false

        guard advertise(created) else {
            embersign_pair_destroy(created)
            handle = nil
            return
        }
        keepAliveWhileInSettings()
        expiry = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { _ in
            Task { @MainActor in
                EmberOnDevicePairing.shared.stop(message: "Pairing timed out. Start again when you are ready to open Developer Mode.")
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var bytes: UnsafeMutablePointer<UInt8>?
            var length = 0
            var device: UnsafeMutablePointer<CChar>?
            var error: UnsafeMutablePointer<CChar>?
            let result = embersign_pair_wait(
                created,
                { pin, _ in
                    guard let pin else { return }
                    let code = String(cString: pin)
                    Task { @MainActor in EmberOnDevicePairing.shared.showPIN(code) }
                },
                nil, &bytes, &length, &device, &error
            )
            let record = bytes.map { Data(bytes: $0, count: length) }
            embersign_pair_free_bytes(bytes, length)
            let deviceName = Self.consume(device)
            let explanation = Self.consume(error)
            Task { @MainActor in
                EmberOnDevicePairing.shared.complete(result: result, record: record,
                                                     name: deviceName, explanation: explanation)
            }
        }
    }

    func stop(message: String? = nil) {
        guard let handle else { return }
        embersign_pair_cancel(handle)
        stopAdvertising()
        phase = message.map(Phase.failed) ?? .idle
    }

    func reset() {
        guard !active && handle == nil else { return }
        phase = .idle
    }

    private func advertise(_ session: OpaquePointer) -> Bool {
        var text = TXTRecordRef()
        TXTRecordCreate(&text, 0, nil)
        defer { TXTRecordDeallocate(&text) }

        for index in 0..<embersign_pair_txt_count(session) {
            guard let key = embersign_pair_txt_key(session, index),
                  let value = embersign_pair_txt_value(session, index) else { continue }
            TXTRecordSetValue(&text, key, UInt8(clamping: strlen(value)), value)
        }

        var service: DNSServiceRef?
        let status = DNSServiceRegister(
            &service, 0, 0, embersign_pair_service_name(session),
            "_remotepairing-pairable-host._tcp", nil, nil,
            embersign_pair_port(session).bigEndian,
            TXTRecordGetLength(&text), TXTRecordGetBytesPtr(&text),
            { _, _, code, _, _, _, _ in
                if code != DNSServiceErrorType(kDNSServiceErr_NoError) {
                    Task { @MainActor in
                        EmberOnDevicePairing.shared.stop(
                            message: "iOS could not publish the pairing host (DNS-SD error \(code)). Allow Local Network access and retry."
                        )
                    }
                }
            }, nil
        )
        guard status == DNSServiceErrorType(kDNSServiceErr_NoError), let service else {
            phase = .failed("Could not advertise EmberSign for pairing. Check Wi-Fi and Local Network permission (error \(status)).")
            return false
        }
        DNSServiceSetDispatchQueue(service, .main)
        advertisement = service
        return true
    }

    private func stopAdvertising() {
        if let advertisement { DNSServiceRefDeallocate(advertisement) }
        advertisement = nil
    }

    private func showPIN(_ value: String) {
        guard active else { return }
        phase = .enterPIN(value)
        if #available(iOS 26.0, *), let task = continuousTask as? BGContinuedProcessingTask {
            task.updateTitle("EmberSign pairing code: \(value)",
                             subtitle: "Enter this code in Settings > Developer Mode")
            task.progress.completedUnitCount = 1
        }
        if UIApplication.shared.applicationState != .active {
            let notice = UNMutableNotificationContent()
            notice.title = "EmberSign pairing code: \(value)"
            notice.body = "Enter this code in Settings > Privacy & Security > Developer Mode."
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "embersign.pairing.pin", content: notice, trigger: nil)
            )
        }
    }

    private func complete(result: Int32, record: Data?, name: String?, explanation: String?) {
        if let handle { embersign_pair_destroy(handle) }
        handle = nil
        stopAdvertising()
        expiry?.invalidate()
        expiry = nil
        guard result == 0 else {
            if result != 2 {
                phase = .failed(explanation ?? "Remote pairing failed. Verify the code and try again.")
            }
            finishBackground(success: false)
            return
        }
        do {
            guard let record else { throw EmberError.message("The pairing service did not produce a record.") }
            try EmberPairingStore.saveGeneratedRemote(record)
            phase = .paired(name ?? "This iPhone")
            finishBackground(success: true)
        } catch {
            phase = .failed("Pairing completed, but saving its credentials failed: \(error.localizedDescription)")
            finishBackground(success: false)
        }
    }

    nonisolated private static func consume(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { embersign_pair_free_string(pointer) }
        return String(cString: pointer)
    }

    private func keepAliveWhileInSettings() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        graceTask = UIApplication.shared.beginBackgroundTask(withName: "EmberSign pairing") {
            Task { @MainActor in
                let session = EmberOnDevicePairing.shared
                if session.continuousTask == nil && session.active {
                    session.stop(message: "iOS suspended EmberSign before pairing completed. Start again and open Developer Mode promptly.")
                }
                session.endGrace()
            }
        }
        if #available(iOS 26.0, *) {
            submitContinuousTask()
        } else {
            limitedBackgroundTime = true
        }
    }

    @available(iOS 26.0, *)
    private func submitContinuousTask() {
        guard let identifier = Bundle.main.bundleIdentifier.map({ "\($0).pairing.session" }) else {
            limitedBackgroundTime = true
            return
        }
        if registeredTaskID != identifier {
            let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { job in
                guard let job = job as? BGContinuedProcessingTask else {
                    job.setTaskCompleted(success: false)
                    return
                }
                Task { @MainActor in EmberOnDevicePairing.shared.attach(job) }
            }
            guard accepted else {
                limitedBackgroundTime = true
                return
            }
            registeredTaskID = identifier
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: "Pairing this iPhone with EmberSign",
            subtitle: "Open Settings > Privacy & Security > Developer Mode"
        )
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) }
        catch { limitedBackgroundTime = true }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        guard active else { task.setTaskCompleted(success: false); return }
        continuousTask = task
        task.progress.totalUnitCount = 2
        if case .enterPIN(let value) = phase {
            task.updateTitle("EmberSign pairing code: \(value)",
                             subtitle: "Enter this code in Settings > Developer Mode")
            task.progress.completedUnitCount = 1
        }
        task.expirationHandler = {
            Task { @MainActor in
                EmberOnDevicePairing.shared.continuousTask = nil
                EmberOnDevicePairing.shared.stop(message: "iOS ended the background pairing task. Retry from EmberSign.")
            }
        }
    }

    private func finishBackground(success: Bool) {
        if #available(iOS 26.0, *), let task = continuousTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        continuousTask = nil
        endGrace()
    }

    private func endGrace() {
        guard graceTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(graceTask)
        graceTask = .invalid
    }
}
