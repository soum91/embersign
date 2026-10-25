import Foundation

enum EmberJITProtocol {
    static func stikURL(bundleID: String) throws -> URL {
        guard !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EmberError.message("Enter the installed app's bundle identifier.")
        }
        var components = URLComponents()
        components.scheme = "stikdebug"
        components.host = "enable-jit"
        components.queryItems = [URLQueryItem(name: "bundle-id", value: bundleID)]
        guard let url = components.url else { throw EmberError.message("Invalid bundle identifier.") }
        return url
    }

    static func serverURL(base: String, components path: [String]) throws -> URL {
        guard let components = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              var url = components.url else {
            throw EmberError.message("Enter a server URL such as http://192.168.1.20:8080.")
        }
        for part in path {
            guard !part.isEmpty, part != ".", part != "..", !part.contains("/"), !part.contains("\\") else {
                throw EmberError.message("Invalid device or app identifier.")
            }
            url.appendPathComponent(part)
        }
        return url
    }

    static func activationMessage(data: Data) throws -> String {
        if let dictionary = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
           let error = dictionary["ERROR"] as? String { throw EmberError.message(error) }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let message = object as? String,
              message.hasPrefix("Enabled JIT for ") || message.hasPrefix("JIT already enabled for ") else {
            throw EmberError.message("The server did not report successful JIT activation.")
        }
        return message
    }
}

enum EmberEntitlementPolicy {
    static func prepare(profile: [String: Any], custom: [String: Any]?, bundleID: String) throws -> [String: Any] {
        guard profile["get-task-allow"] as? Bool == true else {
            throw EmberError.message("JIT requires a development provisioning profile with get-task-allow enabled. Distribution certificates cannot grant this permission.")
        }
        func replace(_ value: Any) -> Any {
            if let string = value as? String { return string.replacingOccurrences(of: "*", with: bundleID) }
            if let array = value as? [Any] { return array.map(replace) }
            if let dictionary = value as? [String: Any] { return dictionary.mapValues(replace) }
            return value
        }
        var result = profile.mapValues(replace)
        if let custom { result.merge(custom) { _, new in new } }
        // These identities come from the profile, never from an unrelated app's signature.
        for key in ["application-identifier", "com.apple.developer.team-identifier"] {
            if let value = profile[key] { result[key] = replace(value) }
        }
        result["get-task-allow"] = true
        return result
    }
}
