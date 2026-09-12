import XCTest

final class WorkerEntitlementTestSupportTests: XCTestCase {
    private let approved: [String: Any] = [
        "com.apple.security.app-sandbox": true,
        "com.apple.security.inherit": true,
    ]

    private var exactMutation: [String: Any] {
        var value = approved
        value["com.apple.security.temporary-exception.files.absolute-path.read-only"] = ["/"]
        value["com.apple.security.temporary-exception.mach-lookup.global-name"] = [
            "com.apple.testmanagerd",
            "com.apple.dt.testmanagerd.runner",
            "com.apple.coresymbolicationd",
        ]
        return value
    }

    func testApprovedProductionEntitlementsAreAccepted() throws {
        XCTAssertEqual(try WorkerEntitlementTestSupport.signedState(entitlements: approved), .approved)
    }

    func testExactKnownMutationIsRecognized() throws {
        XCTAssertEqual(try WorkerEntitlementTestSupport.signedState(entitlements: exactMutation), .xcode26TestActionMutation)
    }

    func testMissingApprovedKeyFails() {
        XCTAssertThrowsError(try WorkerEntitlementTestSupport.signedState(entitlements: [
            "com.apple.security.app-sandbox": true,
        ]))
    }

    func testExtraKeyFails() {
        var value = exactMutation
        value["unexpected"] = true
        XCTAssertThrowsError(try WorkerEntitlementTestSupport.signedState(entitlements: value))
    }

    func testWrongApprovedTypeOrValueFails() {
        var wrongType = approved
        wrongType["com.apple.security.inherit"] = "true"
        XCTAssertThrowsError(try WorkerEntitlementTestSupport.signedState(entitlements: wrongType))

        var wrongValue = approved
        wrongValue["com.apple.security.app-sandbox"] = false
        XCTAssertThrowsError(try WorkerEntitlementTestSupport.signedState(entitlements: wrongValue))
    }

    func testPropertyListBooleanTrueIsAccepted() throws {
        let entitlements = try roundTrippedEntitlements(appSandboxValue: "<true/>")
        XCTAssertEqual(try WorkerEntitlementTestSupport.signedState(entitlements: entitlements), .approved)
    }

    func testPropertyListBooleanFalseFails() throws {
        let entitlements = try roundTrippedEntitlements(appSandboxValue: "<false/>")
        XCTAssertThrowsError(try WorkerEntitlementTestSupport.signedState(entitlements: entitlements))
    }

    func testPropertyListIntegerOneFails() throws {
        let entitlements = try roundTrippedEntitlements(appSandboxValue: "<integer>1</integer>")
        XCTAssertThrowsError(try WorkerEntitlementTestSupport.signedState(entitlements: entitlements))
    }

    func testPropertyListIntegerZeroFails() throws {
        let entitlements = try roundTrippedEntitlements(appSandboxValue: "<integer>0</integer>")
        XCTAssertThrowsError(try WorkerEntitlementTestSupport.signedState(entitlements: entitlements))
    }

    func testPropertyListStringTrueFails() throws {
        let entitlements = try roundTrippedEntitlements(appSandboxValue: "<string>true</string>")
        XCTAssertThrowsError(try WorkerEntitlementTestSupport.signedState(entitlements: entitlements))
    }

    func testExactMutationWithIntegerBackedApprovedEntitlementFails() throws {
        var mutation = exactMutation
        let integerEntitlements = try roundTrippedEntitlements(appSandboxValue: "<integer>1</integer>")
        mutation["com.apple.security.app-sandbox"] = integerEntitlements["com.apple.security.app-sandbox"]
        XCTAssertThrowsError(try WorkerEntitlementTestSupport.signedState(entitlements: mutation))
    }

    func testWrongTemporaryExceptionTypesFail() {
        var wrongPathType = exactMutation
        wrongPathType["com.apple.security.temporary-exception.files.absolute-path.read-only"] = "/"
        XCTAssertThrowsError(try WorkerEntitlementTestSupport.signedState(entitlements: wrongPathType))

        var duplicateName = exactMutation
        duplicateName["com.apple.security.temporary-exception.mach-lookup.global-name"] = [
            "com.apple.testmanagerd", "com.apple.testmanagerd",
        ]
        XCTAssertThrowsError(try WorkerEntitlementTestSupport.signedState(entitlements: duplicateName))
    }

    func testUnrelatedPathFails() {
        var value = exactMutation
        value["com.apple.security.temporary-exception.files.absolute-path.read-only"] = ["/private/tmp"]
        XCTAssertThrowsError(try WorkerEntitlementTestSupport.signedState(entitlements: value))
    }

    func testUnrelatedServiceNameFails() {
        var value = exactMutation
        value["com.apple.security.temporary-exception.mach-lookup.global-name"] = ["com.example.unrelated"]
        XCTAssertThrowsError(try WorkerEntitlementTestSupport.signedState(entitlements: value))
    }

    private func roundTrippedEntitlements(appSandboxValue: String) throws -> [String: Any] {
        let data = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>com.apple.security.app-sandbox</key>
                \(appSandboxValue)
                <key>com.apple.security.inherit</key>
                <true/>
            </dict>
            </plist>
            """.utf8)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(object as? [String: Any])
    }
}
