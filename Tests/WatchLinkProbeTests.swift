import XCTest
@testable import EmberCore

final class WatchLinkProbeTests: XCTestCase {
    let group = "group.dev.test123.watchlink.probe"
    func profile(_ groups: Any? = nil) throws -> Data {
        var entitlements: [String: Any] = [:]
        entitlements[EmberWatchLinkProbe.groupKey] = groups
        let xml = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": entitlements], format: .xml, options: 0)
        return Data([1, 2, 3]) + xml + Data([4, 5])
    }
    func words(_ values: [UInt32], big: Bool) -> Data {
        Data(values.flatMap { value -> [UInt8] in
            let shifts = big ? [24, 16, 8, 0] : [0, 8, 16, 24]
            return shifts.map { UInt8(truncatingIfNeeded: value >> $0) }
        })
    }
    func executable(_ groups: [String]) throws -> Data {
        let xml = try PropertyListSerialization.data(fromPropertyList: [EmberWatchLinkProbe.groupKey: groups], format: .xml, options: 0)
        let entitlement = words([0xfade7171, UInt32(8 + xml.count)], big: true) + xml
        let signature = words([0xfade0cc0, UInt32(20 + entitlement.count), 1, 5, 20], big: true) + entitlement
        let header = words([0xfeedfacf, 0x0100000c, 0, 2, 1, 16, 0, 0], big: false)
        let command = words([0x1d, 16, 48, UInt32(signature.count)], big: false)
        return header + command + signature
    }
    func testDedicatedGroupOnlyForExactWatchLinkPlan() throws {
        let plan = EmberWatchBundlePlan(targets: [
            .init(kind: .iphoneApp, bundleID: "dev.watchlink.companion", relativePath: "."),
            .init(kind: .watchApp, bundleID: "dev.watchlink.companion.watchapp", relativePath: "PlugIns/Watch.app")
        ])
        XCTAssertEqual(try EmberWatchLinkProbe.groupID(plan: plan, teamID: "TEST123"), group)
        XCTAssertThrowsError(try EmberWatchLinkProbe.groupID(plan: plan, teamID: "bad/team"))
        XCTAssertNil(try EmberWatchLinkProbe.groupID(plan: .init(targets: [
            .init(kind: .iphoneApp, bundleID: "other.app", relativePath: "."),
            .init(kind: .watchApp, bundleID: "other.app.watch", relativePath: "PlugIns/Watch.app")
        ]), teamID: "TEST123"))
        XCTAssertThrowsError(try EmberWatchLinkProbe.groupID(plan: .init(targets: plan.targets + [
            .init(kind: .watchWidget, bundleID: "unexpected", relativePath: "extra")
        ]), teamID: "TEST123"))
    }
    func testProfileMustActuallyAuthorizeExactGroup() throws {
        XCTAssertNoThrow(try EmberWatchLinkProbe.requireGroup(group, profile: profile([group, "group.other"])))
        XCTAssertThrowsError(try EmberWatchLinkProbe.requireGroup(group, profile: profile()))
        XCTAssertThrowsError(try EmberWatchLinkProbe.requireGroup(group, profile: profile(["group.other"])))
        XCTAssertThrowsError(try EmberWatchLinkProbe.requireGroup(group, profile: profile(["group.*"])))
        XCTAssertThrowsError(try EmberWatchLinkProbe.requireGroup(group, profile: profile("wrong type")))
        XCTAssertThrowsError(try EmberWatchLinkProbe.requireGroup(group, profile: Data("invalid".utf8)))
    }
    func testEverySignedArchitectureMustRetainGroup() throws {
        let good = try executable([group])
        let bad = try executable([])
        XCTAssertNoThrow(try EmberWatchLinkProbe.requireSignedGroup(group, executable: good))
        XCTAssertThrowsError(try EmberWatchLinkProbe.requireSignedGroup(group, executable: bad))
        func fat(_ second: Data) -> Data {
            words([0xcafebabe, 2, 0x0100000c, 0, 48, UInt32(good.count), 0,
                   0x0200000c, 0, UInt32(48 + good.count), UInt32(second.count), 0], big: true) + good + second
        }
        XCTAssertNoThrow(try EmberWatchLinkProbe.requireSignedGroup(group, executable: fat(good)))
        XCTAssertThrowsError(try EmberWatchLinkProbe.requireSignedGroup(group, executable: fat(bad)))
        for count in [0, 3, 12, 31, 47, good.count - 1] {
            XCTAssertThrowsError(try EmberWatchLinkProbe.requireSignedGroup(group, executable: good.prefix(count)))
        }
        var invalidOffset = good
        invalidOffset.replaceSubrange(40..<44, with: words([UInt32.max], big: false))
        XCTAssertThrowsError(try EmberWatchLinkProbe.requireSignedGroup(group, executable: invalidOffset))
    }
}
