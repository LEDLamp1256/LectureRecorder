import CoreFoundation
import Foundation
import XCTest

enum WorkerEntitlementTestSupport {
    enum SignedState: Equatable {
        case approved
        case xcode26TestActionMutation
    }

    private static let approvedKeys: Set<String> = [
        "com.apple.security.app-sandbox",
        "com.apple.security.inherit",
    ]

    private static let xcode26InjectedKeys: Set<String> = [
        "com.apple.security.temporary-exception.files.absolute-path.read-only",
        "com.apple.security.temporary-exception.mach-lookup.global-name",
    ]

    private static let xcode26ReadOnlyPaths: Set<String> = ["/"]

    private static let xcode26MachLookupNames: Set<String> = [
        "com.apple.testmanagerd",
        "com.apple.dt.testmanagerd.runner",
        "com.apple.coresymbolicationd",
    ]

    static let xcode26SkipMessage = """
        Xcode 26.6 mutated the test-action product by injecting exactly the two known temporary-exception entitlements. An inherit-entitled helper cannot validly launch with those injected keys. Normal-build verification and the external signed launch harness provide the real launch proof.
        """

    static func requireLaunchableSignature(at helperURL: URL) throws {
        if try signedState(at: helperURL) == .xcode26TestActionMutation {
            throw XCTSkip(xcode26SkipMessage)
        }
    }

    static func signedState(at helperURL: URL) throws -> SignedState {
        let entitlements = try readSignedEntitlements(at: helperURL)
        return try signedState(entitlements: entitlements)
    }

    static func signedState(entitlements: [String: Any]) throws -> SignedState {
        guard isGenuineTrueCFBoolean(entitlements["com.apple.security.app-sandbox"]) else {
            throw ValidationError("Signed helper is missing com.apple.security.app-sandbox=true")
        }
        guard isGenuineTrueCFBoolean(entitlements["com.apple.security.inherit"]) else {
            throw ValidationError("Signed helper is missing com.apple.security.inherit=true")
        }

        let keys = Set(entitlements.keys)
        if keys == approvedKeys {
            return .approved
        }
        if keys == approvedKeys.union(xcode26InjectedKeys) {
            let paths = try exactStringArray(
                entitlements["com.apple.security.temporary-exception.files.absolute-path.read-only"],
                key: "com.apple.security.temporary-exception.files.absolute-path.read-only"
            )
            guard paths == xcode26ReadOnlyPaths else {
                throw ValidationError("Unexpected Xcode 26.6 read-only exception paths: \(paths.sorted())")
            }

            let names = try exactStringArray(
                entitlements["com.apple.security.temporary-exception.mach-lookup.global-name"],
                key: "com.apple.security.temporary-exception.mach-lookup.global-name"
            )
            guard names == xcode26MachLookupNames else {
                throw ValidationError("Unexpected Xcode 26.6 mach-lookup exception names: \(names.sorted())")
            }
            return .xcode26TestActionMutation
        }
        throw ValidationError("Unexpected signed helper entitlement keys: \(keys.sorted())")
    }

    /// Swift's `as? Bool` accepts integer-backed `NSNumber(1)` through
    /// Foundation bridging. Entitlement validation must distinguish a real
    /// plist Boolean from an integer that merely has a truthy value.
    private static func isGenuineTrueCFBoolean(_ value: Any?) -> Bool {
        guard let value,
              CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else {
            return false
        }
        return (value as? Bool) == true
    }

    private static func exactStringArray(_ value: Any?, key: String) throws -> Set<String> {
        guard let strings = value as? [String], Set(strings).count == strings.count else {
            throw ValidationError("Entitlement \(key) must be an array of unique strings")
        }
        return Set(strings)
    }

    private static func readSignedEntitlements(at helperURL: URL) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", "-", "--xml", helperURL.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ValidationError(
                "codesign entitlement inspection failed with status \(process.terminationStatus): "
                    + String(decoding: diagnostic.prefix(4096), as: UTF8.self)
            )
        }
        let object = try PropertyListSerialization.propertyList(from: output, options: [], format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw ValidationError("Signed entitlements did not decode as a dictionary")
        }
        return dictionary
    }

    private struct ValidationError: LocalizedError {
        let message: String

        init(_ message: String) {
            self.message = message
        }

        var errorDescription: String? { message }
    }
}
