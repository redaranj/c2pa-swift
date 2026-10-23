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
//  ContextTests.swift
//

import C2PA
import class C2PA.Stream
import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class CallbackRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func record(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    var recorded: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Serves one canned response to every request and records the requests.
private final class StubURLProtocol: URLProtocol {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var status = 200
        private var body = Data()
        private var requests: [URLRequest] = []

        func stub(status: Int, body: Data) {
            lock.lock()
            defer { lock.unlock() }
            self.status = status
            self.body = body
            requests = []
        }

        func response() -> (status: Int, body: Data) {
            lock.lock()
            defer { lock.unlock() }
            return (status, body)
        }

        func record(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            requests.append(request)
        }

        var recorded: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    static let state = State()

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.record(request)
        let stub = Self.state.response()
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty { client?.urlProtocol(self, didLoad: stub.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serialized: the URLSession tests share StubURLProtocol's recorded state.
@Suite(.serialized) struct ContextTests {

    private static let remoteManifestURL = URL(string: "https://example.com/manifests/test.c2pa")!

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Signs Pexels with no embedded manifest and a remote reference, returning
    /// the asset and the manifest a server would host.
    private func signWithRemoteManifest() throws -> (asset: Data, manifest: Data) {
        let output = Fixtures.tempURL(extension: "jpg")
        defer { try? FileManager.default.removeItem(at: output) }
        let builder = try Builder(manifestJSON: Fixtures.createdManifestJSON())
        builder.setNoEmbed()
        try builder.setRemote(url: Self.remoteManifestURL)
        let manifest = try builder.sign(
            format: "image/jpeg", source: Fixtures.stream(Fixtures.pexelsJPEG), destination: Stream(writeTo: output),
            signer: Fixtures.signer())
        return (try Data(contentsOf: output), manifest)
    }

    private func remoteFetchSettings() throws -> C2PASettings {
        try C2PASettings(json: #"{"version": 1, "verify": {"remote_manifest_fetch": true}}"#)
    }

    private func remoteFetchContext(httpResolver: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) throws -> C2PAContext {
        try C2PAContext(settings: remoteFetchSettings(), httpResolver: httpResolver)
    }

    private func signThroughContext(_ context: C2PAContext) throws -> ManifestStore {
        try Fixtures.signAndRead(Builder(context: context, manifestJSON: Fixtures.createdManifestJSON()))
    }

    // MARK: - Creation and settings

    @Test func contextDefaultCreation() throws {
        let reader = try Reader(context: C2PAContext(), format: "image/jpeg", stream: Fixtures.stream(Fixtures.adobeJPEG))
        #expect(try ManifestStore(json: reader.json()).activeLabel == Fixtures.adobeActiveManifest)
    }

    @Test func contextFromSettings() throws {
        let settings = try C2PASettings(json: #"{"version": 1, "builder": {"thumbnail": {"enabled": false}}}"#)
        #expect(try signThroughContext(C2PAContext(settings: settings)).active["thumbnail"] == nil)
    }

    @Test func builderFromContext() throws {
        #expect(try signThroughContext(C2PAContext()).assertionLabels().contains("c2pa.test"))
    }

    @Test func settingsFlowRoundtrip() throws {
        let settings = try C2PASettings(json: #"{"version": 1, "verify": {"verify_after_reading": true}}"#)
        let store = try signThroughContext(C2PAContext(settings: settings))
        #expect(try store.assertionLabels() == ["c2pa.actions.v2", "c2pa.test"])
        #expect(store.validationState == "Valid")
    }

    @Test func contextWithSettingsAndCallbacks() throws {
        let progress = CallbackRecorder<ProgressPhase>()
        let resolverCalls = CallbackRecorder<HTTPRequest>()
        let context = try C2PAContext(
            settings: C2PASettings(json: #"{"version": 1, "builder": {"thumbnail": {"enabled": false}}}"#),
            onProgress: {
                progress.record($0.phase)
                return .continue
            },
            httpResolver: {
                resolverCalls.record($0)
                return HTTPResponse(status: 204, body: Data())
            })
        let store = try signThroughContext(context)
        #expect(try store.active["thumbnail"] == nil, "settings applied")
        #expect(!progress.recorded.isEmpty, "progress observer called")
        #expect(resolverCalls.recorded.isEmpty, "nothing to fetch when signing a local asset")
    }

    // MARK: - Cancellation

    /// cancel() reaches in-progress operations only; with nothing running it
    /// must not poison the next one.
    @Test func contextCancel() throws {
        let context = try C2PAContext()
        try context.cancel()
        withKnownIssue("cancel() stays in force and fails later operations") {
            let labels = try signThroughContext(context).assertionLabels()
            #expect(labels.contains("c2pa.test"))
        }
    }

    /// cancel() is callable from another thread, and like contextCancel it
    /// leaves the context usable when nothing was in flight.
    @Test func contextCancelFromAnotherThread() async throws {
        let context = try C2PAContext()
        try await Task.detached { try context.cancel() }.value
        withKnownIssue("cancel() stays in force and fails later operations") {
            let labels = try signThroughContext(context).assertionLabels()
            #expect(labels.contains("c2pa.test"))
        }
    }

    @Test func progressCallback() throws {
        let recorder = CallbackRecorder<ProgressPhase>()
        let context = try C2PAContext(onProgress: {
            recorder.record($0.phase)
            return .continue
        })
        _ = try signThroughContext(context)
        let observed = recorder.recorded
        #expect(!observed.contains(.unknown), "a phase did not map to a known case, so the native enum has drifted")
        #expect(observed.contains(.hashing) || observed.contains(.signing), "observed \(observed)")
    }

    @Test func progressCallbackCancelsOperation() throws {
        let recorder = CallbackRecorder<ProgressPhase>()
        let context = try C2PAContext(onProgress: {
            recorder.record($0.phase)
            return .cancel
        })
        #expect(throws: C2PAError.self, "sign completed although the observer asked to cancel") {
            try signThroughContext(context)
        }
        #expect(!recorder.recorded.isEmpty, "sign failed before any progress was reported")
    }

    // MARK: - HTTP resolvers

    /// A resolver is only consulted for remote content: reading an embedded
    /// manifest must not call it.
    @Test func httpResolver() throws {
        let calls = CallbackRecorder<HTTPRequest>()
        let context = try C2PAContext(httpResolver: {
            calls.record($0)
            return HTTPResponse(status: 500, body: Data())
        })
        let reader = try Reader(context: context, format: "image/jpeg", stream: Fixtures.stream(Fixtures.adobeJPEG))
        #expect(try ManifestStore(json: reader.json()).activeLabel == Fixtures.adobeActiveManifest)
        #expect(calls.recorded.isEmpty)
    }

    @Test func urlSessionHTTPResolver() throws {
        StubURLProtocol.state.stub(status: 500, body: Data())
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        let reader = try Reader(context: C2PAContext(urlSession: session), format: "image/jpeg", stream: Fixtures.stream(Fixtures.adobeJPEG))
        #expect(try ManifestStore(json: reader.json()).activeLabel == Fixtures.adobeActiveManifest)
        #expect(StubURLProtocol.state.recorded.isEmpty)
    }

    @Test func httpResolverRemoteManifestFetch() throws {
        let (asset, manifest) = try signWithRemoteManifest()
        let requests = CallbackRecorder<HTTPRequest>()
        let context = try remoteFetchContext { request in
            requests.record(request)
            return HTTPResponse(status: 200, body: manifest)
        }
        let reader = try Reader(context: context, format: "image/jpeg", stream: Stream(data: asset))
        let json = try reader.json()

        let request = try #require(requests.recorded.first)
        #expect(requests.recorded.count == 1)
        #expect(request.url == Self.remoteManifestURL)
        #expect(request.method == "GET")
        #expect(request.body == nil, "a GET request carried a body")
        #expect(reader.remote() == Self.remoteManifestURL)
        #expect(try ManifestStore(json: json).assertionLabels().contains("c2pa.test"))
    }

    @Test func httpResolverErrorFailsRead() throws {
        struct ResolverRefused: LocalizedError {
            static let message = "resolver refused this request on purpose"
            var errorDescription: String? { Self.message }
        }
        let (asset, _) = try signWithRemoteManifest()
        let requests = CallbackRecorder<HTTPRequest>()
        let context = try remoteFetchContext { request in
            requests.record(request)
            throw ResolverRefused()
        }
        let error = try #require(throws: C2PAError.self) {
            try Reader(context: context, format: "image/jpeg", stream: Stream(data: asset))
        }
        #expect(requests.recorded.count == 1)
        #expect(error.localizedDescription.contains(ResolverRefused.message), "resolver error text did not reach the caller: \(error)")
    }

    @Test func httpResolverRejectsOutOfRangeStatus() throws {
        let (asset, manifest) = try signWithRemoteManifest()
        let context = try remoteFetchContext { _ in HTTPResponse(status: Int(Int32.max) + 1, body: manifest) }
        let error = try #require(throws: C2PAError.self) {
            try Reader(context: context, format: "image/jpeg", stream: Stream(data: asset))
        }
        #expect(error.localizedDescription.contains("out of range"), "error: \(error)")
    }

    @Test func httpResolverEmptyResponseBody() throws {
        let (asset, _) = try signWithRemoteManifest()
        let context = try remoteFetchContext { _ in HTTPResponse(status: 204, body: Data()) }
        #expect(throws: C2PAError.self, "read succeeded although the resolver served no manifest") {
            try Reader(context: context, format: "image/jpeg", stream: Stream(data: asset))
        }
    }

    @Test func urlSessionResolverRejectsMainQueueSession() {
        let session = URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: .main)
        defer { session.invalidateAndCancel() }
        let error = #expect(throws: C2PAError.self) { try C2PAContext(urlSession: session) }
        #expect(error?.localizedDescription.contains("main queue") == true, "error: \(String(describing: error))")
    }

    @Test func urlSessionResolverFetchesRemoteManifest() throws {
        let (asset, manifest) = try signWithRemoteManifest()
        StubURLProtocol.state.stub(status: 200, body: manifest)
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        let context = try C2PAContext(settings: remoteFetchSettings(), urlSession: session)
        let json = try Reader(context: context, format: "image/jpeg", stream: Stream(data: asset)).json()

        let request = try #require(StubURLProtocol.state.recorded.first)
        #expect(StubURLProtocol.state.recorded.count == 1)
        #expect(request.url == Self.remoteManifestURL)
        #expect(request.httpMethod == "GET")
        #expect(try ManifestStore(json: json).assertionLabels().contains("c2pa.test"))
    }
}
