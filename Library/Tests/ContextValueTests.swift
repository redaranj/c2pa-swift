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
//  ContextValueTests.swift
//

import C2PA
import Foundation
import Testing

/// The values a context hands to its callbacks. An application builds them itself to test the
/// progress observer or HTTP resolver it wrote, so this suite imports the library the way an
/// application does, without `@testable`.
@Suite struct ContextValueTests {

    // MARK: - ProgressUpdate

    @Test func progressUpdateCanBeBuilt() {
        let update = ProgressUpdate(phase: .hashing, step: 3, total: 10)
        #expect(update.phase == .hashing)
        #expect(update.step == 3)
        #expect(update.total == 10)
    }

    /// With a total above one the phase is determinate. The fraction stays within 0...1 even
    /// for a step outside the total, which a hand-built update can have.
    @Test(arguments: [(1, 4, 0.25), (2, 4, 0.5), (4, 4, 1.0), (0, 4, 0.0), (5, 4, 1.0), (-1, 4, 0.0)])
    func fractionCompletedOfADeterminatePhase(step: Int, total: Int, fraction: Double) {
        #expect(ProgressUpdate(phase: .hashing, step: step, total: total).fractionCompleted == fraction)
    }

    /// A total of zero is an indeterminate phase and a total of one a single-shot phase.
    /// Neither gives a fraction to show.
    @Test(arguments: [0, 1, -3])
    func fractionCompletedIsNilWithoutATotalToMeasureAgainst(total: Int) {
        #expect(ProgressUpdate(phase: .signing, step: 1, total: total).fractionCompleted == nil)
    }

    // MARK: - ProgressPhase

    @Test func unknownPhasesAreToldApartByTheirNativeValue() {
        #expect(ProgressPhase.unknown(14) == .unknown(14))
        #expect(ProgressPhase.unknown(14) != .unknown(15))
        #expect(ProgressPhase.unknown(14) != .hashing)
        #expect(String(describing: ProgressPhase.unknown(14)) == "unknown(14)")
    }

    // MARK: - HTTPRequest

    @Test func httpRequestCanBeBuilt() throws {
        let url = try #require(URL(string: "https://example.com/ocsp"))
        let request = HTTPRequest(
            url: url, method: "POST", headers: ["Content-Type": "application/ocsp-request"], body: Data([1, 2, 3]))
        #expect(request.url == url)
        #expect(request.method == "POST")
        #expect(request.headers == ["Content-Type": "application/ocsp-request"])
        #expect(request.body == Data([1, 2, 3]))
    }

    @Test func httpRequestDefaultsToNoHeadersAndNoBody() throws {
        let request = HTTPRequest(url: try #require(URL(string: "https://example.com/manifest")), method: "GET")
        #expect(request.headers.isEmpty)
        #expect(request.body == nil)
    }

    /// The point of the public initializers: a resolver written as a function can be tested
    /// without driving a signing or reading operation.
    @Test func aResolverFunctionCanBeTestedOnItsOwn() throws {
        @Sendable func resolver(_ request: HTTPRequest) throws -> HTTPResponse {
            HTTPResponse(status: request.method == "GET" ? 200 : 405, body: Data(request.url.path.utf8))
        }
        let url = try #require(URL(string: "https://example.com/manifest"))
        #expect(try resolver(HTTPRequest(url: url, method: "GET")).status == 200)
        #expect(try resolver(HTTPRequest(url: url, method: "POST")).status == 405)
    }
}
