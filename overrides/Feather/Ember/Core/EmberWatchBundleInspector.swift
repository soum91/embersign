import Foundation

/// A read-only inventory of the signing identities an iPhone/Watch package needs.
/// No certificate or installation decision may be inferred from the host profile.
public struct EmberWatchBundlePlan: Equatable {
    public struct Target: Equatable {
        public enum Kind: String {
            case iphoneApp
            case watchApp
            case watchWidget
        }

        public let kind: Kind
        public let bundleID: String
        public let relativePath: String
    }

    public let targets: [Target]

    public var hasWatchCompanion: Bool { targets.contains { $0.kind == .watchApp } }
    public var requiredBundleIDs: [String] { targets.map(\.bundleID) }

    /// Report a missing per-target profile instead of reusing an iPhone profile.
    public func validateProfiles(_ profiles: [String: Data]) throws {
        for target in targets where profiles[target.bundleID]?.isEmpty != false {
            throw EmberWatchBundleError.missingProfile(target.bundleID)
        }
    }
}

public enum EmberWatchBundleError: Error, LocalizedError, Equatable {
    case missingInfoPlist(String)
    case invalidBundleID(String)
    case companionMismatch(String)
    case invalidWidgetIdentifier(String)
    case duplicateBundleID(String)
    case missingProfile(String)

    public var errorDescription: String? {
        switch self {
        case .missingInfoPlist(let path): return "Missing or unreadable Info.plist: \(path)"
        case .invalidBundleID(let path): return "Missing or invalid bundle identifier: \(path)"
        case .companionMismatch(let path): return "Watch companion does not match the iPhone app: \(path)"
        case .invalidWidgetIdentifier(let path): return "Watch widget bundle ID does not belong to its Watch app: \(path)"
        case .duplicateBundleID(let id): return "Duplicate bundle identifier: \(id)"
        case .missingProfile(let id): return "Separate provisioning profile required for \(id)."
        }
    }
}

public enum EmberWatchBundleInspector {
    /// Supports the legacy Watch/ layout and Xcode 26+ PlugIns/ watch app layout.
    /// Only reads Info.plist files; imported IPA contents are never modified.
    public static func inspect(iphoneApp: URL) throws -> EmberWatchBundlePlan {
        let manager = FileManager.default

        func metadata(_ bundle: URL) throws -> [String: Any] {
            let plist = bundle.appendingPathComponent("Info.plist")
            guard let data = try? Data(contentsOf: plist),
                  let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw EmberWatchBundleError.missingInfoPlist(bundle.lastPathComponent)
            }
            return dictionary
        }

        func identifier(_ bundle: URL, _ info: [String: Any]) throws -> String {
            guard let value = info["CFBundleIdentifier"] as? String,
                  !value.isEmpty,
                  !value.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw EmberWatchBundleError.invalidBundleID(bundle.lastPathComponent)
            }
            return value
        }

        func children(of root: URL, extension ext: String) -> [URL] {
            guard let items = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                return []
            }
            return items.filter { $0.pathExtension == ext && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        let hostInfo = try metadata(iphoneApp)
        let hostID = try identifier(iphoneApp, hostInfo)
        var targets = [EmberWatchBundlePlan.Target(kind: .iphoneApp, bundleID: hostID, relativePath: ".")]
        var seen = Set([hostID])

        // Do not classify an App Clip as a Watch app. A Watch app must declare
        // the iPhone host in its own WKCompanionAppBundleIdentifier metadata.
        let candidateApps = children(of: iphoneApp.appendingPathComponent("Watch"), extension: "app")
            + children(of: iphoneApp.appendingPathComponent("PlugIns"), extension: "app")
        for watchURL in candidateApps {
            let info = try metadata(watchURL)
            guard let companion = info["WKCompanionAppBundleIdentifier"] as? String else { continue }
            guard companion == hostID else {
                throw EmberWatchBundleError.companionMismatch(watchURL.lastPathComponent)
            }
            let watchID = try identifier(watchURL, info)
            guard watchID.hasPrefix(hostID + ".") else {
                throw EmberWatchBundleError.companionMismatch(watchURL.lastPathComponent)
            }
            guard seen.insert(watchID).inserted else { throw EmberWatchBundleError.duplicateBundleID(watchID) }

            let relativePath = watchURL.path.replacingOccurrences(of: iphoneApp.path + "/", with: "")
            targets.append(.init(kind: .watchApp, bundleID: watchID, relativePath: relativePath))

            for widgetURL in children(of: watchURL.appendingPathComponent("PlugIns"), extension: "appex") {
                let widgetInfo = try metadata(widgetURL)
                let extensionInfo = widgetInfo["NSExtension"] as? [String: Any]
                guard extensionInfo?["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension" else { continue }
                let widgetID = try identifier(widgetURL, widgetInfo)
                guard widgetID.hasPrefix(watchID + ".") else {
                    throw EmberWatchBundleError.invalidWidgetIdentifier(widgetURL.lastPathComponent)
                }
                guard seen.insert(widgetID).inserted else { throw EmberWatchBundleError.duplicateBundleID(widgetID) }
                let widgetPath = widgetURL.path.replacingOccurrences(of: iphoneApp.path + "/", with: "")
                targets.append(.init(kind: .watchWidget, bundleID: widgetID, relativePath: widgetPath))
            }
        }
        return EmberWatchBundlePlan(targets: targets)
    }
}
