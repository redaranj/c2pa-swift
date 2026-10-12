// This file is licensed to you under the Apache License, Version 2.0 
// (http://www.apache.org/licenses/LICENSE-2.0) or the MIT license 
// (http://opensource.org/licenses/MIT), at your option.
//
// Unless required by applicable law or agreed to in writing, this software is 
// distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS OF 
// ANY KIND, either express or implied. See the LICENSE-MIT and LICENSE-APACHE 
// files for the specific language governing permissions and limitations under
// each license.

import Foundation
import TestShared

// Test runner for UI - aggregates all test suites
public final class TestRunner: Sendable {

    public init() {}

    // Run all test suites and return results
    public func runAllTests() async -> [TestSuiteResult] {
        var suites: [TestSuiteResult] = []

        for suite in TestSuite.allCases {
            let results = await runTestSuite(suite)
            suites.append(TestSuiteResult(name: suite.displayName, results: results))
        }

        return suites
    }

    // Run a specific test suite
    public func runTestSuite(_ suite: TestSuite) async -> [TestResult] {
        switch suite {
        case .stream:
            await StreamTests().runAllTests()
        case .builder:
            await BuilderTests().runAllTests()
        case .reader:
            await ReaderTests().runAllTests()
        case .signing:
            await SigningTests().runAllTests()
        case .signerExtended:
            await SignerExtendedTests().runAllTests()
        case .certificateManager:
            await CertificateManagerTests().runAllTests()
        case .hardwareSigning:
            await HardwareSigningTests().runAllTests()
        case .secureEnclave:
            await SecureEnclaveSignerTests().runAllTests()
        case .keychainSigner:
            await KeychainSignerTests().runAllTests()
        case .webServiceSigner:
            await WebServiceSignerTests().runAllTests()
        case .comprehensive:
            await ComprehensiveTests().runAllTests()
        case .manifest:
            await ManifestTests().runAllTests()
        case .assertionDefinition:
            await AssertionDefinitionTests().runAllTests()
        case .settingsDefinition:
            await SettingsDefinitionTests().runAllTests()
        case .context:
            await ContextTests().runAllTests()
        case .convenience:
            await ConvenienceTests().runAllTests()
        }
    }
}

// Available test suites
public enum TestSuite: String, CaseIterable, Sendable {
    case stream = "Stream"
    case builder = "Builder"
    case reader = "Reader"
    case signing = "Signing"
    case signerExtended = "Signer Extended"
    case certificateManager = "Certificate Manager"
    case hardwareSigning = "Hardware Signing"
    case secureEnclave = "Secure Enclave"
    case keychainSigner = "Keychain Signer"
    case webServiceSigner = "Web Service Signer"
    case comprehensive = "Comprehensive"
    case manifest = "Manifest"
    case assertionDefinition = "Assertion Definition"
    case settingsDefinition = "Settings Definition"
    case context = "Context"
    case convenience = "Convenience"

    public var displayName: String {
        return rawValue + " Tests"
    }
}

// Test suite result container
public struct TestSuiteResult: Sendable {
    public let name: String
    public let results: [TestResult]

    public init(name: String, results: [TestResult]) {
        self.name = name
        self.results = results
    }

    public var passedCount: Int {
        results.filter { $0.passed }.count
    }

    public var skippedCount: Int {
        results.filter { $0.skipped }.count
    }

    public var failedCount: Int {
        results.filter { !$0.passed && !$0.skipped }.count
    }

    public var totalCount: Int {
        results.count
    }

    public var passRate: Double {
        guard totalCount > 0 else { return 0 }
        return Double(passedCount) / Double(totalCount)
    }
}
