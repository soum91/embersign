import Foundation

enum EmberJITEntitlements {
    static func prepare(certificate: CertificatePair?, existingFile: URL?, bundleID: String, output: URL) throws -> URL {
        guard let certificate,
              let profile = CertificateReader(Storage.shared.getFile(.provision, from: certificate)).decoded,
              profile.ExpirationDate > Date() else {
            throw EmberError.message("Select a valid development certificate and provisioning profile before preparing an app for JIT.")
        }
        var custom: [String: Any]?
        if let existingFile {
            guard let dictionary = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: existingFile), options: [], format: nil
            ) as? [String: Any] else { throw EmberError.message("The custom entitlements file is invalid.") }
            custom = dictionary
        }
        let result = try EmberEntitlementPolicy.prepare(
            profile: (profile.Entitlements ?? [:]).mapValues { $0.value },
            custom: custom,
            bundleID: bundleID
        )
        let data = try PropertyListSerialization.data(fromPropertyList: result, format: .xml, options: 0)
        try data.write(to: output, options: .atomic)
        return output
    }
}
