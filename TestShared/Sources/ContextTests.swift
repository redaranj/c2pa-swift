// This file is licensed to you under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0) or the MIT license
// (http://opensource.org/licenses/MIT), at your option.
//
// Unless required by applicable law or agreed to in writing, this software is
// distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR REPRESENTATIONS OF
// ANY KIND, either express or implied. See the LICENSE-MIT and LICENSE-APACHE
// files for the specific language governing permissions and limitations under
// each license.

import C2PA
import Foundation

// Context API tests - pure Swift implementation
public final class ContextTests: TestImplementation {

    public init() {}

    public func testContextDefaultCreation() -> TestResult {
        do {
            _ = try C2PAContext()
            return .success("Context Default Creation", "[PASS] Created default C2PAContext")
        } catch {
            return .failure("Context Default Creation", "Error: \(error)")
        }
    }

    public func testContextFromSettings() -> TestResult {
        do {
            let settings = try C2PASettings(json: "{\"version\": 1}")
            _ = try C2PAContext(settings: settings)
            return .success("Context From Settings", "[PASS] Created C2PAContext from settings")
        } catch {
            return .failure("Context From Settings", "Error: \(error)")
        }
    }

    public func testContextCancel() -> TestResult {
        do {
            let context = try C2PAContext()
            try context.cancel()
            return .success("Context Cancel", "[PASS] cancel() returned without error")
        } catch {
            return .failure("Context Cancel", "Error: \(error)")
        }
    }

    public func testBuilderFromContext() -> TestResult {
        do {
            let manifestJSON = TestUtilities.createTestManifestJSON()
            let context = try C2PAContext()
            _ = try Builder(context: context, manifestJSON: manifestJSON)
            return .success("Builder From Context", "[PASS] Created Builder from context")
        } catch {
            return .failure("Builder From Context", "Error: \(error)")
        }
    }

    public func runAllTests() async -> [TestResult] {
        [
            testContextDefaultCreation(),
            testContextFromSettings(),
            testContextCancel(),
            testBuilderFromContext(),
        ]
    }
}
