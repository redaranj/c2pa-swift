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
//  ProgressPhaseTests.swift
//

import Testing

@testable import C2PA

/// How the native progress phase values map to ``ProgressPhase``.
@Suite struct ProgressPhaseTests {

    /// The phases in the order of their native values, which start at zero.
    private static let known: [ProgressPhase] = [
        .reading, .verifyingManifest, .verifyingSignature, .verifyingIngredient, .verifyingAssetHash,
        .addingIngredient, .thumbnail, .hashing, .signing, .embedding, .fetchingRemoteManifest, .writing,
        .fetchingOCSP, .fetchingTimestamp
    ]

    @Test func everyNativePhaseMapsToItsCase() {
        for (value, phase) in Self.known.enumerated() {
            #expect(ProgressPhase(.init(rawValue: UInt32(value))) == phase)
        }
    }

    /// A value past the ones this version knows is kept, so a report of it names the phase.
    @Test(arguments: [UInt32(14), 9_999])
    func aPhaseThisVersionDoesNotKnowKeepsItsNativeValue(value: UInt32) {
        #expect(ProgressPhase(.init(rawValue: value)) == .unknown(value))
    }
}
