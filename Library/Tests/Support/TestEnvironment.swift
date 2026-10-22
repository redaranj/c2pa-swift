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

    /// The result of creating and deleting a permanent P-256 key. Without a
    /// keychain entitlement (unsigned CI builds) this is errSecMissingEntitlement.
    static let keychainProbeStatus: OSStatus = {
        let tag = Data("org.contentauth.test.probe.\(UUID().uuidString)".utf8)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard SecKeyCreateRandomKey(attributes as CFDictionary, &error) != nil else {
            let status = error.map { OSStatus(truncatingIfNeeded: ($0.takeRetainedValue() as Error as NSError).code) }
            return status ?? errSecParam
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
        ]
        _ = SecItemDelete(query as CFDictionary)
        return errSecSuccess
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
