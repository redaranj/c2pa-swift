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
//  C2PAContext.swift
//

import C2PAC
import Foundation

/// A phase of a C2PA signing or reading operation. Maps the native `C2paProgressPhase`.
public enum ProgressPhase {
    case reading, verifyingManifest, verifyingSignature, verifyingIngredient,
         verifyingAssetHash, addingIngredient, thumbnail, hashing, signing,
         embedding, fetchingRemoteManifest, writing, fetchingOCSP, fetchingTimestamp
    /// A phase value not known to this version of the wrapper.
    case unknown

    init(_ phase: C2paProgressPhase) {
        switch phase {
        case Reading: self = .reading
        case VerifyingManifest: self = .verifyingManifest
        case VerifyingSignature: self = .verifyingSignature
        case VerifyingIngredient: self = .verifyingIngredient
        case VerifyingAssetHash: self = .verifyingAssetHash
        case AddingIngredient: self = .addingIngredient
        case Thumbnail: self = .thumbnail
        case Hashing: self = .hashing
        case Signing: self = .signing
        case Embedding: self = .embedding
        case FetchingRemoteManifest: self = .fetchingRemoteManifest
        case Writing: self = .writing
        case FetchingOCSP: self = .fetchingOCSP
        case FetchingTimestamp: self = .fetchingTimestamp
        default: self = .unknown
        }
    }
}

/// A progress update delivered during a signing or reading operation.
public struct ProgressUpdate {
    /// The current operation phase.
    public let phase: ProgressPhase
    /// Monotonically increasing within a phase (starts at 1); rising values indicate liveness.
    public let step: UInt32
    /// `0` = indeterminate, `1` = single-shot, `> 1` = determinate (`step / total`).
    public let total: UInt32
}

private final class ProgressCallbackBox {
    let onProgress: (ProgressUpdate) -> Void
    init(_ onProgress: @escaping (ProgressUpdate) -> Void) { self.onProgress = onProgress }
}

/// An HTTP request the SDK needs resolved (remote manifest, OCSP, or timestamp fetch).
public struct HTTPRequest {
    /// The request URL.
    public let url: URL
    /// The HTTP method (e.g. `"GET"`).
    public let method: String
    /// Request headers.
    public let headers: [String: String]
    /// The request body, if any.
    public let body: Data?
}

/// The HTTP response a resolver returns.
public struct HTTPResponse {
    /// The HTTP status code.
    public let status: Int
    /// The response body.
    public let body: Data
    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

private final class HTTPResolverBox {
    let resolve: (HTTPRequest) throws -> HTTPResponse
    init(_ resolve: @escaping (HTTPRequest) throws -> HTTPResponse) { self.resolve = resolve }
}

/// An immutable, shareable configuration context for creating builders.
///
/// `C2PAContext` wraps the native context produced by ``C2PAContextBuilder``.
/// Once built, a context is immutable and can be used to create one or more
/// ``Builder`` instances that share the same configuration (settings such as
/// created-assertion labels, trust configuration, and CAWG signer settings).
///
/// ## Topics
///
/// ### Creating a Context
/// - ``init()``
/// - ``init(settings:)``
///
/// ### Controlling Operations
/// - ``cancel()``
///
/// ### Progress
/// - ``C2PAContextBuilder/setProgressCallback(_:)``
///
/// ## Example
///
/// ```swift
/// let settings = try C2PASettings(json: settingsJSON)
/// let context = try C2PAContext(settings: settings)
/// let builder = try Builder(context: context, manifestJSON: manifestJSON)
/// ```
///
/// - SeeAlso: ``C2PAContextBuilder``, ``C2PASettings``, ``Builder``
public final class C2PAContext {
    let ptr: UnsafeMutablePointer<C2paContext>
    private let callbackBoxes: [AnyObject]

    /// Internal initializer that adopts an already-built native context.
    init(ptr: UnsafeMutablePointer<C2paContext>, callbackBoxes: [AnyObject] = []) {
        self.ptr = ptr
        self.callbackBoxes = callbackBoxes
    }

    /// Creates a context with default settings.
    ///
    /// - Throws: ``C2PAError`` if the context cannot be created.
    public convenience init() throws {
        self.init(ptr: try guardNotNull(c2pa_context_new()))
    }

    /// Creates a context configured with the given settings.
    ///
    /// The settings are cloned by the C layer, so the caller retains ownership
    /// of `settings`.
    ///
    /// - Parameter settings: The ``C2PASettings`` to configure this context with.
    ///
    /// - Throws: ``C2PAError`` if the context cannot be created.
    public convenience init(settings: C2PASettings) throws {
        let builder = try C2PAContextBuilder()
        try builder.setSettings(settings)
        self.init(ptr: try builder.buildPtr())
    }

    deinit { _ = c2pa_free(ptr) }

    /// Requests cancellation of any in-progress signing or reading operation
    /// running on this context.
    ///
    /// - Throws: ``C2PAError`` if the cancellation request fails.
    public func cancel() throws {
        guard c2pa_context_cancel(ptr) == 0 else {
            throw C2PAError.api(lastC2PAError())
        }
    }
}

/// A configurable builder that produces an immutable ``C2PAContext``.
///
/// Use `C2PAContextBuilder` when you need to apply settings before building a
/// context. For the common cases, prefer the ``C2PAContext`` convenience
/// initializers.
///
/// ## Topics
///
/// ### Building a Context
/// - ``init()``
/// - ``setSettings(_:)``
/// - ``setProgressCallback(_:)``
/// - ``setHTTPResolver(_:)``
/// - ``setHTTPResolver(urlSession:)``
/// - ``build()``
///
/// ## Example
///
/// ```swift
/// let context = try C2PAContextBuilder()
///     .setSettings(settings)
///     .build()
/// ```
///
/// - SeeAlso: ``C2PAContext``, ``C2PASettings``
public final class C2PAContextBuilder {
    private var ptr: UnsafeMutablePointer<C2paContextBuilder>?
    private var callbackBoxes: [AnyObject] = []

    /// Creates a new, empty context builder.
    ///
    /// - Throws: ``C2PAError`` if the builder cannot be created.
    public init() throws {
        self.ptr = try guardNotNull(c2pa_context_builder_new())
    }

    /// Applies settings to the context being built.
    ///
    /// The settings are cloned by the C layer, so the caller retains ownership.
    ///
    /// - Parameter settings: The ``C2PASettings`` to apply.
    ///
    /// - Returns: This builder, to allow chaining.
    ///
    /// - Throws: ``C2PAError`` if the builder has already been built, or the
    ///   settings cannot be applied.
    @discardableResult
    public func setSettings(_ settings: C2PASettings) throws -> Self {
        guard let ptr else {
            throw C2PAError.api("Context builder has already been built")
        }
        _ = try guardNonNegative(
            Int64(c2pa_context_builder_set_settings(ptr, settings.rawPtr))
        )
        return self
    }

    /// Installs a closure that observes progress of operations run on the built context.
    ///
    /// The closure is called synchronously at operation checkpoints. To cancel an
    /// in-progress operation, call ``C2PAContext/cancel()``.
    ///
    /// - Parameter onProgress: Called with each ``ProgressUpdate``.
    /// - Returns: This builder, to allow chaining.
    /// - Throws: ``C2PAError`` if the builder has already been built, or the callback cannot be set.
    @discardableResult
    public func setProgressCallback(_ onProgress: @escaping (ProgressUpdate) -> Void) throws -> Self {
        guard let ptr else {
            throw C2PAError.api("Context builder has already been built")
        }
        let box = ProgressCallbackBox(onProgress)
        callbackBoxes.append(box)
        let trampoline: ProgressCCallback = { context, phase, step, total in
            guard let context else { return 1 }
            let box = Unmanaged<ProgressCallbackBox>.fromOpaque(context).takeUnretainedValue()
            box.onProgress(ProgressUpdate(phase: ProgressPhase(phase), step: step, total: total))
            return 1  // always continue; cancellation is via C2PAContext.cancel()
        }
        _ = try guardNonNegative(Int64(
            c2pa_context_builder_set_progress_callback(ptr, Unmanaged.passUnretained(box).toOpaque(), trampoline)))
        return self
    }

    /// Installs a custom resolver for HTTP requests the SDK makes (remote manifests,
    /// OCSP, timestamps).
    ///
    /// The resolver is called synchronously and may be invoked from any thread, so its
    /// closure must be thread-safe. Throwing an error fails the request.
    ///
    /// - Parameter resolve: Resolves an ``HTTPRequest`` to an ``HTTPResponse``.
    /// - Returns: This builder, to allow chaining.
    /// - Throws: ``C2PAError`` if the builder has already been built, or the resolver cannot be set.
    @discardableResult
    public func setHTTPResolver(_ resolve: @escaping (HTTPRequest) throws -> HTTPResponse) throws -> Self {
        guard let ptr else {
            throw C2PAError.api("Context builder has already been built")
        }
        let box = HTTPResolverBox(resolve)
        callbackBoxes.append(box)
        let trampoline: C2paHttpResolverCallback = { context, request, response in
            guard let context, let request, let response else { return 1 }
            let box = Unmanaged<HTTPResolverBox>.fromOpaque(context).takeUnretainedValue()
            let req = request.pointee
            guard let urlPtr = req.url, let url = URL(string: String(cString: urlPtr)) else {
                _ = "Invalid request URL".withCString { c2pa_error_set_last($0) }
                return 1
            }
            let method = req.method.map { String(cString: $0) } ?? "GET"
            var headers: [String: String] = [:]
            if let h = req.headers {
                for line in String(cString: h).split(separator: "\n") {
                    if let colon = line.firstIndex(of: ":") {
                        let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty { headers[name] = value }
                    }
                }
            }
            let body: Data? = (req.body != nil && req.body_len > 0)
                ? Data(bytes: req.body!, count: Int(req.body_len)) : nil
            do {
                let result = try box.resolve(HTTPRequest(url: url, method: method, headers: headers, body: body))
                response.pointee.status = Int32(result.status)
                if result.body.isEmpty {
                    response.pointee.body = nil
                    response.pointee.body_len = 0
                } else {
                    let buf = malloc(result.body.count)!.assumingMemoryBound(to: UInt8.self)
                    result.body.copyBytes(to: buf, count: result.body.count)
                    response.pointee.body = buf
                    response.pointee.body_len = UInt(result.body.count)
                }
                return 0
            } catch {
                _ = String(describing: error).withCString { c2pa_error_set_last($0) }
                return 1
            }
        }
        let resolver = try guardNotNull(
            c2pa_http_resolver_create(Unmanaged.passUnretained(box).toOpaque(), trampoline))
        _ = try guardNonNegative(Int64(c2pa_context_builder_set_http_resolver(ptr, resolver)))
        return self
    }

    /// Installs a built-in HTTP resolver backed by `URLSession`.
    ///
    /// Performs each request synchronously (the native resolver call blocks until the
    /// response is ready). Suitable for the common case of fetching remote resources.
    ///
    /// - Parameter urlSession: The session to use. Defaults to `.shared`.
    /// - Returns: This builder, to allow chaining.
    /// - Throws: ``C2PAError`` if the resolver cannot be set.
    @discardableResult
    public func setHTTPResolver(urlSession: URLSession = .shared) throws -> Self {
        try setHTTPResolver { request in
            var resultData: Data?
            var resultStatus = 0
            var resultError: Error?
            let semaphore = DispatchSemaphore(value: 0)
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = request.method
            for (name, value) in request.headers {
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }
            urlRequest.httpBody = request.body
            let task = urlSession.dataTask(with: urlRequest) { data, response, error in
                if let error {
                    resultError = error
                } else {
                    resultData = data ?? Data()
                    resultStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
                }
                semaphore.signal()
            }
            task.resume()
            semaphore.wait()
            if let resultError {
                throw C2PAError.api("HTTP resolver request failed: \(resultError)")
            }
            return HTTPResponse(status: resultStatus, body: resultData ?? Data())
        }
    }

    /// Builds an immutable ``C2PAContext``.
    ///
    /// This consumes the builder; the builder must not be reused afterward.
    ///
    /// - Returns: The configured ``C2PAContext``.
    ///
    /// - Throws: ``C2PAError`` if the builder has already been built, or the
    ///   context cannot be created.
    public func build() throws -> C2PAContext {
        C2PAContext(ptr: try buildPtr(), callbackBoxes: callbackBoxes)
    }

    /// Consumes the native builder and returns the built context pointer.
    func buildPtr() throws -> UnsafeMutablePointer<C2paContext> {
        guard let ptr else {
            throw C2PAError.api("Context builder has already been built")
        }
        self.ptr = nil  // c2pa_context_builder_build consumes the builder, even on error
        return try guardNotNull(c2pa_context_builder_build(ptr))
    }

    deinit {
        if let ptr { _ = c2pa_free(ptr) }
    }
}
