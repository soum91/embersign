import Foundation

struct EmberPairingRecord {
    enum Kind: String { case lockdown = "Lockdown"; case remote = "Remote pairing" }
    let data: Data
    let kind: Kind
    let udid: String?

    init(data: Data) throws {
        guard data.count <= 4 * 1024 * 1024 else {
            throw EmberError.message("The pairing file is too large.")
        }
        guard let dictionary = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            throw EmberError.message("Choose a pairing-file property list.")
        }
        if let publicKey = dictionary["public_key"] as? Data,
           let privateKey = dictionary["private_key"] as? Data,
           publicKey.count == 32, privateKey.count == 32,
           let identifier = dictionary["identifier"] as? String, !identifier.isEmpty {
            kind = .remote
        } else {
            let strings = ["HostID", "SystemBUID"]
            let keys = ["HostCertificate", "HostPrivateKey", "RootCertificate"]
            guard strings.allSatisfy({ !(dictionary[$0] as? String ?? "").isEmpty }),
                  keys.allSatisfy({ !(dictionary[$0] as? Data ?? Data()).isEmpty }) else {
                throw EmberError.message("This file is missing pairing credentials. Import a Lockdown or remote-pairing record from your trusted pairing tool.")
            }
            kind = .lockdown
        }
        self.data = data
        let value = dictionary["UDID"] as? String
        udid = value.flatMap { $0.isEmpty ? nil : $0 }
    }

    var exportName: String {
        kind == .lockdown ? "EmberSign.mobiledevicepairing" : "EmberSign-Remote.plist"
    }
}

enum EmberError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
