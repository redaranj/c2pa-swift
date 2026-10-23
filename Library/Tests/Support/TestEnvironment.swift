// This file is licensed to you under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0) or the MIT license
// (http://opensource.org/licenses/MIT), at your option.
//
// Unless required by applicable law or agreed to in writing, this software is
// distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS OF
// ANY KIND, either express or implied. See the LICENSE-MIT and LICENSE-APACHE
// files for the specific language governing permissions and limitations under
// each license.
//
//  TestEnvironment.swift
//

import Foundation
import Security
import Testing

/// What the current run can reach: a Secure Enclave, a persistent keychain,
/// the signing server. Suites gate on these through the traits below, so a
/// test that cannot run here shows as skipped with the reason, never as passed.
enum TestEnvironment {

    /// True on an iPhone or iPad, where the hardware and keychain suites always
    /// run: a probe never gets the chance to skip them on the phone.
    #if os(iOS) && !targetEnvironment(simulator)
    static let isPhysicalDevice = true
    #else
    static let isPhysicalDevice = false
    #endif

    /// The result of creating and deleting a permanent P-256 key the way the
    /// keychain tests do. Without a keychain entitlement (unsigned CI builds)
    /// this is errSecMissingEntitlement.
    static let keychainProbeStatus: OSStatus = {
        let tag = Fixtures.uniqueKeyTag("probe")
        defer { TestKeychain.deleteKey(tag: tag) }
        do {
            try TestKeychain.createKey(tag: tag)
            return errSecSuccess
        } catch TestKeychainError.keyCreationFailed(let status) {
            return status
        } catch {
            return errSecParam
        }
    }()

    static var keychainAvailable: Bool {
        isPhysicalDevice || keychainProbeStatus == errSecSuccess
    }

    /// On a device the URL comes from the host's Info.plist, which
    /// `make device-setup` points at this Mac; the test plan's loopback default
    /// would name the phone itself.
    static var signingServerURL: URL {
        if isPhysicalDevice,
            let configured = Bundle.main.object(forInfoDictionaryKey: "C2PASigningServerDeviceURL") as? String,
            let url = URL(string: configured), url.host != nil
        {
            return url
        }
        if let configured = ProcessInfo.processInfo.environment["SIGNING_SERVER_URL"],
            let url = URL(string: configured), url.host != nil
        {
            return url
        }
        return URL(string: "http://127.0.0.1:8080")!
    }

    static var signingServerToken: String {
        ProcessInfo.processInfo.environment["SIGNING_SERVER_TOKEN"] ?? "test-bearer-token-12345"
    }

    /// When true an unreachable server fails the run instead of skipping the
    /// server suites: always on a device, and under make tests-with-server or CI.
    static var signingServerRequired: Bool {
        isPhysicalDevice || ProcessInfo.processInfo.environment["C2PA_REQUIRE_SIGNING_SERVER"] == "1"
    }

    /// What to run when the server cannot be reached. On a device the URL
    /// comes from make device-setup; without it the plan's loopback default
    /// names the phone itself.
    static var signingServerInstructions: String {
        isPhysicalDevice
            ? "Run make device-setup and make signing-server-start-lan on the Mac (or use make test-device), then run again."
            : "Start it with make signing-server-start (make tests-with-server starts and stops it for you)."
    }

    /// Fails the calling test, with the instructions, when the server is down.
    static func requireSigningServer(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try #require(
            await signingServerReachable(),
            "Signing server not reachable at \(signingServerURL). \(signingServerInstructions)",
            sourceLocation: sourceLocation)
    }

    static func signingServerReachable() async -> Bool {
        var request = URLRequest(url: signingServerURL.appendingPathComponent("health"))
        request.timeoutInterval = 5
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

extension Trait where Self == ConditionTrait {

    static var requiresSecureEnclave: Self {
        .enabled(if: TestEnvironment.isPhysicalDevice, "Requires a physical iOS device with a Secure Enclave")
    }

    static var requiresKeychain: Self {
        .enabled(
            if: TestEnvironment.keychainAvailable,
            Comment(rawValue: "Persistent keychain unavailable (OSStatus \(TestEnvironment.keychainProbeStatus))"))
    }

    static var requiresSigningServer: Self {
        .enabled(Comment(rawValue: "Signing server not reachable at \(TestEnvironment.signingServerURL)")) {
            if TestEnvironment.signingServerRequired { return true }
            return await TestEnvironment.signingServerReachable()
        }
    }
}
