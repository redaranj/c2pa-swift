// This file is licensed to you under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0) or the MIT license
// (http://opensource.org/licenses/MIT), at your option.
//
// Unless required by applicable law or agreed to in writing, this software is
// distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS OF
// ANY KIND, either express or implied. See the LICENSE-MIT and LICENSE-APACHE
// files for the specific language governing permissions and limitations under
// each license.

import TestShared
import Testing
import XCTest

@testable import C2PA

// Swift Testing drivers for the TestShared implementations.
//
// Each shared suite lists its tests as data, so one parameterized test per suite runs
// all of them, with the shared test's method name as the argument.

/// Runs one shared test by name and records its result.
private func run<Suite: TestImplementation>(
    _ name: String, in suite: Suite.Type, sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let test = try #require(
        Suite().allTests.first { $0.name == name },
        "\(Suite.self) has no test named \(name)", sourceLocation: sourceLocation)
    let result = await test.run()
    if result.skipped {
        try Test.cancel(Comment(rawValue: result.message), sourceLocation: sourceLocation)
    }
    #expect(result.passed, Comment(rawValue: result.message), sourceLocation: sourceLocation)
}

// On macOS the xctest runner lacks the entitlements to reach the Secure Enclave and the
// Keychain, so tests that need real hardware are disabled there. They run via TestApp on
// iOS devices.
private let runningOnMacOS: Bool = {
    #if os(macOS)
    true
    #else
    false
    #endif
}()

/// The Secure Enclave tests that touch real hardware. The rest of that suite runs
/// everywhere.
private let secureEnclaveHardwareTests: Set<String> = [
    "testDeleteNonExistentKey",
    "testDeleteKeyIdempotent",
    "testSecureEnclaveAvailabilityCheck",
    "testCreateKeyAccessControlValidation",
    "testES256AcceptedBySecureEnclave"
]

// Serialized to keep the one-at-a-time execution these tests had under XCTest. Swift
// Testing would otherwise run the cases of a parameterized test in parallel.
@Suite(.serialized)
struct SharedSuiteTests {
    @Test("Stream", arguments: TestShared.StreamTests.testNames)
    func stream(_ name: String) async throws {
        try await run(name, in: TestShared.StreamTests.self)
    }

    @Test("Builder", arguments: TestShared.BuilderTests.testNames)
    func builder(_ name: String) async throws {
        try await run(name, in: TestShared.BuilderTests.self)
    }

    @Test("Reader", arguments: TestShared.ReaderTests.testNames)
    func reader(_ name: String) async throws {
        try await run(name, in: TestShared.ReaderTests.self)
    }

    @Test("Signing", arguments: TestShared.SigningTests.testNames)
    func signing(_ name: String) async throws {
        try await run(name, in: TestShared.SigningTests.self)
    }

    @Test("Comprehensive", arguments: TestShared.ComprehensiveTests.testNames)
    func comprehensive(_ name: String) async throws {
        try await run(name, in: TestShared.ComprehensiveTests.self)
    }

    @Test(
        "Hardware Signing",
        .disabled(
            if: runningOnMacOS,
            "Hardware signing tests require a host app with Keychain entitlements"),
        arguments: TestShared.HardwareSigningTests.testNames)
    func hardwareSigning(_ name: String) async throws {
        try await run(name, in: TestShared.HardwareSigningTests.self)
    }

    @Test("Manifest", arguments: TestShared.ManifestTests.testNames)
    func manifest(_ name: String) async throws {
        try await run(name, in: TestShared.ManifestTests.self)
    }

    @Test("Certificate Manager", arguments: TestShared.CertificateManagerTests.testNames)
    func certificateManager(_ name: String) async throws {
        try await run(name, in: TestShared.CertificateManagerTests.self)
    }

    @Test("Keychain Signer", arguments: TestShared.KeychainSignerTests.testNames)
    func keychainSigner(_ name: String) async throws {
        try await run(name, in: TestShared.KeychainSignerTests.self)
    }

    @Test(
        "Secure Enclave Signer",
        arguments: TestShared.SecureEnclaveSignerTests.testNames.filter {
            !secureEnclaveHardwareTests.contains($0)
        })
    func secureEnclaveSigner(_ name: String) async throws {
        try await run(name, in: TestShared.SecureEnclaveSignerTests.self)
    }

    @Test(
        "Secure Enclave Signer (hardware)",
        .disabled(
            if: runningOnMacOS,
            "Secure Enclave tests require a host app with Keychain entitlements"),
        arguments: TestShared.SecureEnclaveSignerTests.testNames.filter {
            secureEnclaveHardwareTests.contains($0)
        })
    func secureEnclaveSignerHardware(_ name: String) async throws {
        try await run(name, in: TestShared.SecureEnclaveSignerTests.self)
    }

    @Test("C2PA Convenience", arguments: TestShared.ConvenienceTests.testNames)
    func convenience(_ name: String) async throws {
        try await run(name, in: TestShared.ConvenienceTests.self)
    }

    @Test("Signer Extended", arguments: TestShared.SignerExtendedTests.testNames)
    func signerExtended(_ name: String) async throws {
        try await run(name, in: TestShared.SignerExtendedTests.self)
    }

    @Test("Web Service Signer", arguments: TestShared.WebServiceSignerTests.testNames)
    func webServiceSigner(_ name: String) async throws {
        try await run(name, in: TestShared.WebServiceSignerTests.self)
    }

    @Test("Assertion Definition", arguments: TestShared.AssertionDefinitionTests.testNames)
    func assertionDefinition(_ name: String) async throws {
        try await run(name, in: TestShared.AssertionDefinitionTests.self)
    }

    @Test("Context", arguments: TestShared.ContextTests.testNames)
    func context(_ name: String) async throws {
        try await run(name, in: TestShared.ContextTests.self)
    }

    @Test("Settings Definition", arguments: TestShared.SettingsDefinitionTests.testNames)
    func settingsDefinition(_ name: String) async throws {
        try await run(name, in: TestShared.SettingsDefinitionTests.self)
    }
}

// MARK: - Helpers Tests

// These exercise internal helpers directly, so they live here rather than in the
// shared TestShared target, which only sees the public surface.
final class CStringArrayTests: XCTestCase {

    func testEmptyArrayPassesNull() throws {
        let wasNil = try withCStringArray([]) { $0 == nil }
        XCTAssertTrue(wasNil, "an empty array should pass NULL rather than an empty list")
    }

    func testStringsAreNullTerminated() throws {
        let input = ["c2pa.actions", "cawg.training-mining"]
        let readBack = try withCStringArray(input) { pointer -> [String] in
            guard let pointer else { return [] }
            var result: [String] = []
            var index = 0
            // Read until the terminator, exactly as the C layer does.
            while let element = pointer[index] {
                result.append(String(cString: element))
                index += 1
            }
            return result
        }
        XCTAssertEqual(readBack, input, "the C layer must see every string, in order")
    }

    func testBodyErrorPropagates() {
        struct Sentinel: Error {}
        XCTAssertThrowsError(try withCStringArray(["a"]) { _ -> Int in throw Sentinel() }) { error in
            XCTAssertTrue(error is Sentinel, "an error thrown by body should reach the caller unchanged")
        }
    }
}
