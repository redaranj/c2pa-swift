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

    /// Internal initializer that adopts an already-built native context.
    init(ptr: UnsafeMutablePointer<C2paContext>) {
        self.ptr = ptr
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

    /// Builds an immutable ``C2PAContext``.
    ///
    /// This consumes the builder; the builder must not be reused afterward.
    ///
    /// - Returns: The configured ``C2PAContext``.
    ///
    /// - Throws: ``C2PAError`` if the builder has already been built, or the
    ///   context cannot be created.
    public func build() throws -> C2PAContext {
        C2PAContext(ptr: try buildPtr())
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
