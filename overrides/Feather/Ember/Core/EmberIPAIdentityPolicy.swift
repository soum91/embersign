import Foundation

/// Identity edits are performed before signing. Never rewrite arbitrary strings in an IPA:
/// only bundle identifiers and the specific companion metadata that references them.
public struct EmberIPAIdentityEdit: Equatable {
    public var originalID: String
    public var newID: String
    public var displayName: String
    public var version: String
    public var build: String
    public var minimumIOS: String
    public var replaceURLSchemes: Bool
    public var urlSchemes: String

    public init(originalID: String, newID: String, displayName: String,
                version: String, build: String, minimumIOS: String,
                replaceURLSchemes: Bool = false, urlSchemes: String = "") {
        self.originalID = originalID
        self.newID = newID
        self.displayName = displayName
        self.version = version
        self.build = build
        self.minimumIOS = minimumIOS
        self.replaceURLSchemes = replaceURLSchemes
        self.urlSchemes = urlSchemes
    }
}

public enum EmberIPAIdentityError: LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        guard case .invalid(let reason) = self else { return "Invalid IPA edit." }
        return reason
    }
}

public enum EmberIPAIdentityPolicy {
    public static func validBundleID(_ value: String) -> Bool {
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2, value.count <= 255 else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.count <= 63 &&
            segment.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0)
            }
        }
    }

    public static func mappedIdentifier(_ value: String, from original: String, to replacement: String) -> String {
        if value == original { return replacement }
        if value.hasPrefix(original + ".") {
            return replacement + value.dropFirst(original.count)
        }
        return value
    }

    public static func validate(_ edit: EmberIPAIdentityEdit) throws {
        guard validBundleID(edit.originalID), validBundleID(edit.newID) else {
            throw EmberIPAIdentityError.invalid("Enter a valid reverse-DNS Bundle ID, such as com.example.myapp.")
        }
        guard !edit.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              edit.displayName.count <= 80 else {
            throw EmberIPAIdentityError.invalid("Display name must contain 1–80 characters.")
        }
        func validVersion(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 32 &&
            value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
            }
        }
        guard validVersion(edit.version), validVersion(edit.build) else {
            throw EmberIPAIdentityError.invalid("Version and build must be numeric components separated by dots.")
        }
        guard edit.minimumIOS.isEmpty || validVersion(edit.minimumIOS) else {
            throw EmberIPAIdentityError.invalid("Minimum iOS must be a numeric version (for example 17.0).")
        }
        if edit.replaceURLSchemes {
            for scheme in schemes(edit.urlSchemes) {
                guard scheme.count <= 100,
                      let first = scheme.unicodeScalars.first,
                      CharacterSet.letters.contains(first),
                      scheme.unicodeScalars.allSatisfy({
                          CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+.-").contains($0)
                      }) else {
                    throw EmberIPAIdentityError.invalid("Invalid URL scheme: " + scheme)
                }
            }
        }
    }

    public static func schemes(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Only modifies Info.plist metadata. The IPA must be re-signed after mutation.
    /// isHost controls display name, minimum iOS and URL schemes.
    public static func editedInfo(_ info: [String: Any], edit: EmberIPAIdentityEdit, isHost: Bool) throws -> [String: Any] {
        try validate(edit)
        var output = info
        if let id = info["CFBundleIdentifier"] as? String {
            output["CFBundleIdentifier"] = mappedIdentifier(id, from: edit.originalID, to: edit.newID)
        }
        // Update the explicit links Apple uses to match iPhone <-> Watch <-> extensions.
        for key in ["WKCompanionAppBundleIdentifier", "WKAppBundleIdentifier"] {
            if let value = info[key] as? String {
                output[key] = mappedIdentifier(value, from: edit.originalID, to: edit.newID)
            }
        }
        if let extensionInfo = info["NSExtension"] as? [String: Any],
           var attributes = extensionInfo["NSExtensionAttributes"] as? [String: Any] {
            if let value = attributes["WKAppBundleIdentifier"] as? String {
                attributes["WKAppBundleIdentifier"] = mappedIdentifier(value, from: edit.originalID, to: edit.newID)
                var updatedExtension = extensionInfo
                updatedExtension["NSExtensionAttributes"] = attributes
                output["NSExtension"] = updatedExtension
            }
        }
        output["CFBundleShortVersionString"] = edit.version
        output["CFBundleVersion"] = edit.build
        if isHost {
            output["CFBundleDisplayName"] = edit.displayName
            if !edit.minimumIOS.isEmpty { output["MinimumOSVersion"] = edit.minimumIOS }
            if edit.replaceURLSchemes {
                let list = schemes(edit.urlSchemes)
                output["CFBundleURLTypes"] = list.isEmpty ? [] : [
                    ["CFBundleURLName": edit.newID, "CFBundleURLSchemes": list]
                ]
            }
        }
        return output
    }
}