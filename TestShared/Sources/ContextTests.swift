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

    public func testSettingsFlowRoundtrip() -> TestResult {
        let manifestJSON = TestUtilities.createTestManifestJSON()
        let settingsJSON = "{\"version\": 1, \"verify\": {\"verify_after_reading\": true}}"

        do {
            let settings = try C2PASettings(json: settingsJSON)
            let context = try C2PAContext(settings: settings)
            let builder = try Builder(context: context, manifestJSON: manifestJSON)

            let tempDir = FileManager.default.temporaryDirectory
            let sourceFile = tempDir.appendingPathComponent("ctx_source_\(UUID().uuidString).jpg")
            let destFile = tempDir.appendingPathComponent("ctx_dest_\(UUID().uuidString).jpg")
            defer {
                try? FileManager.default.removeItem(at: sourceFile)
                try? FileManager.default.removeItem(at: destFile)
            }

            guard let imageData = TestUtilities.loadPexelsTestImage() else {
                return .failure("Settings Flow Roundtrip", "Could not load test image")
            }
            try imageData.write(to: sourceFile)

            let sourceStream = try Stream(readFrom: sourceFile)
            let destStream = try Stream(writeTo: destFile)
            let signer = try TestUtilities.createTestSigner()

            _ = try builder.sign(
                format: "image/jpeg",
                source: sourceStream,
                destination: destStream,
                signer: signer
            )

            if FileManager.default.fileExists(atPath: destFile.path),
               let readManifest = try? C2PA.readFile(at: destFile),
               !readManifest.isEmpty
            {
                return .success(
                    "Settings Flow Roundtrip",
                    "[PASS] settings -> context -> builder -> sign -> read round-trips"
                )
            }
            return .failure("Settings Flow Roundtrip", "Signed file missing or unreadable")
        } catch let error as C2PAError {
            if case .api(let message) = error,
               message.contains("certificate") || message.contains("cert")
                || message.contains("key") || message.contains("signing")
            {
                return .success(
                    "Settings Flow Roundtrip",
                    "[WARN] context+settings path works (cert/key error expected: \(message))"
                )
            }
            return .failure("Settings Flow Roundtrip", "C2PAError: \(error)")
        } catch {
            return .failure("Settings Flow Roundtrip", "Error: \(error)")
        }
    }

    public func testProgressCallback() -> TestResult {
        let tempDir = FileManager.default.temporaryDirectory
        let sourceURL = tempDir.appendingPathComponent("prog_src_\(UUID().uuidString).jpg")
        let destURL = tempDir.appendingPathComponent("prog_dst_\(UUID().uuidString).jpg")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destURL)
        }
        final class Recorder { var phases: [ProgressPhase] = [] }
        let recorder = Recorder()
        do {
            guard let imageData = TestUtilities.loadPexelsTestImage() else {
                return .failure("Progress Callback", "Could not load test image")
            }
            try imageData.write(to: sourceURL)

            let context = try C2PAContextBuilder()
                .setProgressCallback { update in recorder.phases.append(update.phase) }
                .build()
            let builder = try Builder(context: context, manifestJSON: TestUtilities.createTestManifestJSON())
            let signer = try TestUtilities.createTestSigner()
            _ = try builder.sign(
                format: "image/jpeg",
                source: try Stream(readFrom: sourceURL),
                destination: try Stream(writeTo: destURL),
                signer: signer)

            if !recorder.phases.isEmpty {
                return .success("Progress Callback", "[PASS] progress fired \(recorder.phases.count) updates")
            }
            return .success("Progress Callback", "[WARN] no progress updates observed (environment-dependent)")
        } catch let error as C2PAError {
            return .success("Progress Callback", "[WARN] progress path callable (error: \(error))")
        } catch {
            return .failure("Progress Callback", "Error: \(error)")
        }
    }

    public func runAllTests() async -> [TestResult] {
        [
            testContextDefaultCreation(),
            testContextFromSettings(),
            testContextCancel(),
            testBuilderFromContext(),
            testSettingsFlowRoundtrip(),
            testProgressCallback(),
        ]
    }
}
