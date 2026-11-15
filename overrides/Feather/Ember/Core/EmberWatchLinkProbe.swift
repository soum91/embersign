import Foundation

/// Provisioning/entitlement preflight only. This does not establish sandbox escape
/// support, validate Apple's CMS signature, or change any pairing records.
public enum EmberWatchLinkProbe {
    public static let groupKey = "com.apple.security.application-groups"
    public static let bundleIDs: Set<String> = [
        "dev.watchlink.companion", "dev.watchlink.companion.watchapp"
    ]

    public static func groupID(plan: EmberWatchBundlePlan, teamID: String) throws -> String? {
        guard plan.targets.first?.bundleID == "dev.watchlink.companion",
              plan.hasWatchCompanion else { return nil }
        guard Set(plan.requiredBundleIDs) == bundleIDs,
              !teamID.isEmpty, teamID.count <= 32,
              teamID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw Failure.invalidPlan
        }
        // Stable, team-specific, and exclusively for WatchLink's disposable probe cache.
        return "group.dev." + teamID.lowercased() + ".watchlink.probe"
    }

    public static func profileEntitlements(_ data: Data) throws -> [String: Any] {
        guard data.count <= 524_288,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)), end.upperBound > start.lowerBound,
              let plist = try PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            throw Failure.invalidProfile
        }
        return entitlements
    }

    public static func groups(in entitlements: [String: Any]) throws -> [String] {
        guard let value = entitlements[groupKey] else { return [] }
        guard let groups = value as? [String], groups.allSatisfy({ $0.hasPrefix("group.") && !$0.contains("*") }) else {
            throw Failure.invalidProfile
        }
        return groups
    }

    public static func requireGroup(_ group: String, profile: Data) throws {
        guard try groups(in: profileEntitlements(profile)).contains(group) else { throw Failure.missingGroup }
    }

    /// Inspect every executable architecture, using LC_CODE_SIGNATURE and the XML
    /// entitlement slot. Refuse missing/truncated/ambiguous metadata before install.
    /// This is a consistency check, not cryptographic code-signature verification.
    public static func requireSignedGroup(_ group: String, executable: Data) throws {
        let bytes = [UInt8](executable)
        func word(_ offset: Int, _ big: Bool = false) throws -> Int {
            guard offset >= 0, offset <= bytes.count - 4 else { throw Failure.invalidExecutable }
            let b = Array(bytes[offset..<offset + 4])
            return big ? b.reduce(0) { ($0 << 8) | Int($1) }
                       : b.reversed().reduce(0) { ($0 << 8) | Int($1) }
        }
        func range(_ offset: Int, _ count: Int, within limit: Int) throws -> Range<Int> {
            guard offset >= 0, count >= 0, limit <= bytes.count, offset <= limit, count <= limit - offset else {
                throw Failure.invalidExecutable
            }
            return offset..<offset + count
        }
        var slices: [(Int, Int)] = [(0, bytes.count)]
        let magic = try word(0, true)
        if magic == 0xcafebabe || magic == 0xbebafeca {
            let big = magic == 0xcafebabe
            let count = try word(4, big)
            guard (1...16).contains(count) else { throw Failure.invalidExecutable }
            _ = try range(8, count * 20, within: bytes.count)
            slices = try (0..<count).map { index in
                let offset = try word(8 + index * 20 + 8, big)
                let size = try word(8 + index * 20 + 12, big)
                _ = try range(offset, size, within: bytes.count)
                return (offset, size)
            }
        }
        for (base, size) in slices {
            let end = base + size
            _ = try range(base, 28, within: end)
            let magic = try word(base)
            guard magic == 0xfeedfacf || magic == 0xfeedface else { throw Failure.invalidExecutable }
            let header = magic == 0xfeedfacf ? 32 : 28
            let count = try word(base + 16)
            let commandsSize = try word(base + 20)
            guard count <= 4096 else { throw Failure.invalidExecutable }
            let commands = try range(base + header, commandsSize, within: end)
            var cursor = commands.lowerBound
            var signature: Range<Int>?
            for _ in 0..<count {
                _ = try range(cursor, 8, within: commands.upperBound)
                let cmd = try word(cursor), length = try word(cursor + 4)
                guard length >= 8 else { throw Failure.invalidExecutable }
                _ = try range(cursor, length, within: commands.upperBound)
                if cmd == 0x1d {
                    guard length >= 16, signature == nil else { throw Failure.invalidExecutable }
                    signature = try range(base + word(cursor + 8), word(cursor + 12), within: end)
                }
                cursor += length
            }
            guard let signature else { throw Failure.invalidExecutable }
            let start = signature.lowerBound
            _ = try range(start, 12, within: signature.upperBound)
            guard try word(start, true) == 0xfade0cc0 else { throw Failure.invalidExecutable }
            let blobSize = try word(start + 4, true), slots = try word(start + 8, true)
            let blob = try range(start, blobSize, within: signature.upperBound)
            guard slots <= 64 else { throw Failure.invalidExecutable }
            _ = try range(start + 12, slots * 8, within: blob.upperBound)
            var entitlements: [String: Any]?
            for index in 0..<slots {
                let slot = start + 12 + index * 8
                if try word(slot, true) != 5 { continue }
                guard entitlements == nil else { throw Failure.invalidExecutable }
                let offset = try word(slot + 4, true)
                let entry = start + offset
                _ = try range(entry, 8, within: blob.upperBound)
                guard try word(entry, true) == 0xfade7171 else { throw Failure.invalidExecutable }
                let length = try word(entry + 4, true)
                guard length >= 8, length <= 524_288 else { throw Failure.invalidExecutable }
                let xml = try range(entry + 8, length - 8, within: blob.upperBound)
                entitlements = try PropertyListSerialization.propertyList(from: Data(bytes[xml]), format: nil) as? [String: Any]
            }
            guard let entitlements, try groups(in: entitlements).contains(group) else { throw Failure.missingSignedGroup }
        }
    }

    public enum Failure: LocalizedError {
        case invalidPlan, invalidProfile, missingGroup, invalidExecutable, missingSignedGroup
        public var errorDescription: String? {
            switch self {
            case .invalidPlan: return "Unexpected WatchLink targets or signing team. Probe provisioning stopped."
            case .invalidProfile: return "Cannot read the profile's App Group authorization. Probe provisioning stopped."
            case .missingGroup: return "Apple's profile does not authorize WatchLink's dedicated probe App Group. Check the selected team's App Groups capability; signing stopped."
            case .invalidExecutable: return "Cannot inspect the signed executable's entitlements. WatchLink installation stopped."
            case .missingSignedGroup: return "The signed executable is missing WatchLink's authorized probe App Group. Installation stopped."
            }
        }
    }
}
