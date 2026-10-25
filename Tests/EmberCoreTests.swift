import XCTest
@testable import EmberCore

final class EmberCoreTests: XCTestCase {
    private func plist(_ dictionary: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }

    func testLockdownRecordPreservesOriginalBytesAndFormat() throws {
        let bytes = try plist([
            "HostID": "test-host", "SystemBUID": "test-system",
            "HostCertificate": Data([1]), "HostPrivateKey": Data([2]),
            "RootCertificate": Data([3]), "UDID": "test-device"
        ])
        let record = try EmberPairingRecord(data: bytes)
        XCTAssertEqual(record.kind, .lockdown)
        XCTAssertEqual(record.data, bytes)
        XCTAssertEqual(record.udid, "test-device")
        XCTAssertTrue(record.exportName.hasSuffix(".mobiledevicepairing"))
    }

    func testUnrelatedAndTruncatedPlistsCannotBecomePairingRecords() throws {
        XCTAssertThrowsError(try EmberPairingRecord(data: plist(["CFBundleIdentifier": "test.app"])))
        XCTAssertThrowsError(try EmberPairingRecord(data: Data("not a plist".utf8)))
        XCTAssertThrowsError(try EmberPairingRecord(data: Data(repeating: 0, count: 4 * 1024 * 1024 + 1)))
    }

    func testRemotePairingRejectsWrongKeySizesAndKeepsDifferentExportFormat() throws {
        let record = try EmberPairingRecord(data: plist([
            "public_key": Data(repeating: 1, count: 32),
            "private_key": Data(repeating: 2, count: 32), "identifier": "test-host"
        ]))
        XCTAssertEqual(record.kind, .remote)
        XCTAssertTrue(record.exportName.hasSuffix(".plist"))
        XCTAssertThrowsError(try EmberPairingRecord(data: plist([
            "public_key": Data([1]), "private_key": Data([2]), "identifier": "test-host"
        ])))
    }

    func testDistributionProfileCannotBeConvertedToDevelopmentPermission() {
        XCTAssertThrowsError(try EmberEntitlementPolicy.prepare(
            profile: ["get-task-allow": false], custom: ["get-task-allow": true], bundleID: "test.app"
        ))
        XCTAssertThrowsError(try EmberEntitlementPolicy.prepare(profile: [:], custom: nil, bundleID: "test.app"))
    }

    func testJITIdentityComesFromSelectedProfile() throws {
        let result = try EmberEntitlementPolicy.prepare(
            profile: ["get-task-allow": true, "application-identifier": "TEAM123456.*",
                      "com.apple.developer.team-identifier": "TEAM123456"],
            custom: ["application-identifier": "OTHERTEAM1.other.app", "get-task-allow": false],
            bundleID: "test.app"
        )
        XCTAssertEqual(result["get-task-allow"] as? Bool, true)
        XCTAssertEqual(result["application-identifier"] as? String, "TEAM123456.test.app")
        XCTAssertEqual(result["com.apple.developer.team-identifier"] as? String, "TEAM123456")
        XCTAssertNil(result["dynamic-codesigning"])
    }

    func testStikDebugUsesDocumentedBundleIDParameter() throws {
        let url = try EmberJITProtocol.stikURL(bundleID: "test.app")
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(parts?.scheme, "stikdebug")
        XCTAssertEqual(parts?.host, "enable-jit")
        XCTAssertEqual(parts?.queryItems?.first?.name, "bundle-id")
        XCTAssertEqual(parts?.queryItems?.first?.value, "test.app")
    }

    func testJITServerRejectsCredentialURLsAndPathInjection() throws {
        for invalid in ["file:///etc/passwd", "ftp://host", "http://user:pass@host", "http://host?key=x"] {
            XCTAssertThrowsError(try EmberJITProtocol.serverURL(base: invalid, components: []))
        }
        XCTAssertThrowsError(try EmberJITProtocol.serverURL(base: "http://localhost:8080", components: ["../other"]))
        let url = try EmberJITProtocol.serverURL(base: "http://localhost:8080", components: ["test-device", "test.app"])
        XCTAssertEqual(url.path, "/test-device/test.app")
    }

    func testHTTP200ErrorBodyIsNotReportedAsJITSuccess() throws {
        for body in [#"{"ERROR":"Missing device"}"#, #""Could not find test.app!""#, #"{"OK":"Refreshed!"}"#] {
            XCTAssertThrowsError(try EmberJITProtocol.activationMessage(data: Data(body.utf8)))
        }
        XCTAssertNoThrow(try EmberJITProtocol.activationMessage(data: Data(#""Enabled JIT for 'App'!""#.utf8)))
    }
}
