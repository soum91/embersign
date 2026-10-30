import Foundation
import Security

/// Parsed metadata from an existing .mobileprovision. Data remains in process memory
/// until the signing screen is closed, and is never uploaded to GitHub or Apple.
struct EmberIOSProvisionProfile: Identifiable {
    let id: String
    let name: String
    let data: Data
    let team: String
    let applicationPattern: String
    let expiration: Date
    let allowedCertificates: [Data]
    let provisionedDevices: [String]
    let provisionsAllDevices: Bool

    func authorizes(_ bundleID: String) -> Bool {
        let expected = team + "." + bundleID
        if applicationPattern == expected { return true }
        // A signed wildcard profile can apply to an extension only when the
        // actual profile entitlements and Apple's platform rules permit it.
        guard applicationPattern.hasSuffix("*") else { return false }
        let prefix = String(applicationPattern.dropLast())
        return expected.hasPrefix(prefix)
    }

    var specificity: Int { applicationPattern.filter { $0 != "*" }.count }
    var isExpired: Bool { expiration <= Date() }

    static func parse(_ data: Data) throws -> EmberIOSProvisionProfile {
        guard (1_000...524_288).contains(data.count),
              let start = data.range(of: Data("<?xml".utf8))?.lowerBound,
              let endRange = data.range(of: Data("</plist>".utf8)),
              endRange.upperBound > start,
              let info = try PropertyListSerialization.propertyList(
                  from: data.subdata(in: start..<endRange.upperBound),
                  format: nil
              ) as? [String: Any] else {
            throw EmberIOSProfileError.invalid("Not a readable Apple provisioning profile.")
        }
        guard let entitlements = info["Entitlements"] as? [String: Any],
              let appID = (entitlements["application-identifier"] as? String)
                    ?? (entitlements["com.apple.application-identifier"] as? String),
              let teamIDs = info["TeamIdentifier"] as? [String],
              let team = teamIDs.first, !team.isEmpty,
              appID.hasPrefix(team + "."),
              let expiration = info["ExpirationDate"] as? Date,
              let developerCertificates = info["DeveloperCertificates"] as? [Data],
              !developerCertificates.isEmpty,
              let platforms = info["Platform"] as? [String],
              platforms.contains("iOS"),
              let uuid = info["UUID"] as? String else {
            throw EmberIOSProfileError.invalid("Missing iOS profile metadata, application identifier or signer certificates.")
        }
        return .init(
            id: uuid,
            name: info["Name"] as? String ?? "Imported profile",
            data: data,
            team: team,
            applicationPattern: appID,
            expiration: expiration,
            allowedCertificates: developerCertificates,
            provisionedDevices: info["ProvisionedDevices"] as? [String] ?? [],
            provisionsAllDevices: info["ProvisionsAllDevices"] as? Bool ?? false
        )
    }
}

enum EmberIOSProfileError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case let .invalid(reason) = self { return reason }
        return "Invalid provisioning profile."
    }
}

/// Read only an already-imported certificate and existing profiles.
/// Never registers an Apple App ID, allocates a device slot, or requests
/// another certificate on the user's free developer account.
enum EmberIOSExistingSigner {
    static func resolve(
        bundleIDs: [String],
        p12: Data,
        password: String,
        availableProfiles: [EmberIOSProvisionProfile],
        deviceUDID: String?
    ) throws -> (identity: EmberWatchSigningIdentity, descriptions: [String]) {
        guard !bundleIDs.isEmpty, !availableProfiles.isEmpty else {
            throw EmberIOSProfileError.invalid("Import the certificate's provisioning profiles before signing.")
        }
        var identities: CFArray?
        let result = SecPKCS12Import(
            p12 as CFData,
            [kSecImportExportPassphrase as String: password] as CFDictionary,
            &identities
        )
        guard result == errSecSuccess,
              let entries = identities as? [[String: Any]],
              let rawIdentity = entries.first?[kSecImportItemIdentity as String] else {
            throw EmberIOSProfileError.invalid(
                "The selected certificate's .p12 cannot be opened. Re-import it with its correct password."
            )
        }
        // Security framework guarantees kSecImportItemIdentity contains SecIdentity.
        // Swift 6 rejects conditional casts to CoreFoundation reference types.
        let identity = rawIdentity as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else {
            throw EmberIOSProfileError.invalid("The imported .p12 has no usable signing certificate.")
        }
        let certificateDER = SecCertificateCopyData(certificate) as Data
        var mappings: [String: Data] = [:]
        var descriptions: [String] = []
        var trustedTeam: String?
        for bundleID in bundleIDs {
            let options = availableProfiles
                .filter { $0.authorizes(bundleID) }
                .sorted { $0.specificity > $1.specificity }
            guard let matching = options.first(where: {
                !$0.isExpired && $0.allowedCertificates.contains(certificateDER)
            }) else {
                let reason = options.isEmpty
                    ? "No matching profile for " + bundleID
                    : "Profile for " + bundleID + " is expired or does not contain the selected certificate."
                throw EmberIOSProfileError.invalid(
                    reason + " Request a matching profile from your certificate provider. The app will not modify Apple account quotas."
                )
            }
            if let team = trustedTeam, team != matching.team {
                throw EmberIOSProfileError.invalid("The app and extension profiles belong to different signing teams.")
            }
            trustedTeam = matching.team
            if !matching.provisionsAllDevices {
                if matching.provisionedDevices.isEmpty {
                    throw EmberIOSProfileError.invalid(
                        "The profile for " + bundleID + " neither provisions all devices nor lists registered devices. " +
                        "It may be an App Store distribution profile, which cannot be sideloaded."
                    )
                }
                if let udid = deviceUDID, !udid.isEmpty,
                   !matching.provisionedDevices.contains(where: {
                       $0.caseInsensitiveCompare(udid) == .orderedSame
                   }) {
                    throw EmberIOSProfileError.invalid(
                        "The profile for " + bundleID + " does not include this iPhone's UDID."
                    )
                }
            }
            mappings[bundleID] = matching.data
            let matchKind = matching.applicationPattern.hasSuffix("*") ? "wildcard" : "exact"
            descriptions.append(bundleID + ": " + matchKind + " profile [" + matching.name + "]")
        }
        return (
            EmberWatchSigningIdentity(p12: p12, profiles: mappings),
            descriptions
        )
    }
}
