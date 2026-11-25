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
//  StreamTests.swift
//

import class C2PA.Stream // swiftlint:disable:this duplicate_imports
import Foundation
import Testing

@testable import C2PA

/// A stream is only proven by the library reading from or writing to it, so
/// each test drives one through a Reader or Builder and checks what came out.
@Suite struct StreamTests {

    private func activeLabel(_ stream: Stream, format: String = "image/jpeg") throws -> String {
        try ManifestStore(json: Reader(format: format, stream: stream).json()).activeLabel
    }

    @Test func streamOperations() throws {
        let stream = try Stream(data: Fixtures.data(Fixtures.adobeJPEG))
        #expect(try activeLabel(stream) == Fixtures.adobeActiveManifest)
    }

    @Test func streamFileOperations() throws {
        #expect(try activeLabel(Stream(readFrom: Fixtures.url(Fixtures.adobeJPEG))) == Fixtures.adobeActiveManifest)

        let output = Fixtures.tempURL(extension: "jpg")
        defer { try? FileManager.default.removeItem(at: output) }
        let builder = try Builder(manifestJSON: Fixtures.createdManifestJSON())
        try builder.sign(
            format: "image/jpeg", source: Fixtures.stream(Fixtures.pexelsJPEG), destination: Stream(writeTo: output),
            signer: Fixtures.signer())
        #expect(try ManifestStore(json: C2PA.readFile(at: output)).assertionLabels().contains("c2pa.test"))
    }

    /// A stream with only write and flush is enough to receive a resource.
    @Test func writeOnlyStreams() throws {
        var captured = Data()
        let sink = try Stream(
            write: { buffer, count in
                captured.append(Data(bytes: buffer, count: count))
                return count
            },
            flush: { 0 })
        let reader = try Reader(format: "image/jpeg", stream: Fixtures.stream(Fixtures.adobeJPEG))
        try reader.resource(uri: Fixtures.adobeThumbnailURI, to: sink)
        #expect(captured.count == 76482)
        #expect(captured.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
    }

    @Test func customStreamCallbacks() throws {
        let data = try Fixtures.data(Fixtures.adobeJPEG)
        var position = 0
        var reads = 0
        var seeks = 0
        let stream = try Stream(
            read: { buffer, count in
                reads += 1
                let size = min(count, data.count - position)
                guard size > 0 else { return 0 }
                data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), from: position..<(position + size))
                position += size
                return size
            },
            seek: { offset, origin in
                seeks += 1
                switch origin.rawValue {
                case 0: position = max(0, offset)
                case 1: position = max(0, position + offset)
                case 2: position = max(0, data.count + offset)
                default: break
                }
                return position
            })
        #expect(try activeLabel(stream) == Fixtures.adobeActiveManifest)
        #expect(reads > 0)
        #expect(seeks > 0)
    }

    /// Signs a 10 MB asset entirely from memory: the Pexels JPEG with 10 MB of
    /// trailing bytes after its end-of-image marker.
    @Test func streamWithLargeData() throws {
        var large = try Fixtures.data(Fixtures.pexelsJPEG)
        large.append(Data(repeating: 0xAB, count: 10_000_000))
        let output = Fixtures.tempURL(extension: "jpg")
        defer { try? FileManager.default.removeItem(at: output) }
        let builder = try Builder(manifestJSON: Fixtures.createdManifestJSON())
        try builder.sign(format: "image/jpeg", source: Stream(data: large), destination: Stream(writeTo: output), signer: Fixtures.signer())

        #expect(try Data(contentsOf: output).count > large.count)
        let store = try ManifestStore(json: C2PA.readFile(at: output))
        #expect(try store.assertionLabels().contains("c2pa.test"))
        #expect(store.validationState == "Valid")
    }

    @Test func multipleStreams() throws {
        let data = try Fixtures.data(Fixtures.adobeJPEG)
        let streams = try (0..<10).map { _ in try Stream(data: data) }
        let labels = try streams.map { try activeLabel($0) }
        #expect(labels == Array(repeating: Fixtures.adobeActiveManifest, count: 10))
    }

    @Test func fileStreamOptions() throws {
        let file = Fixtures.tempURL(extension: "dat")
        defer { try? FileManager.default.removeItem(at: file) }

        _ = try Stream(writeTo: file)
        #expect(FileManager.default.fileExists(atPath: file.path), "writeTo creates the file")

        let content = Data("Stream options test data".utf8)
        try content.write(to: file)
        _ = try Stream(update: file)
        #expect(try Data(contentsOf: file) == content, "update keeps the existing content")

        _ = try Stream(writeTo: file)
        #expect(try Data(contentsOf: file).isEmpty, "writeTo truncates")
    }

    @Test func fileStreamsRequireAnExistingFile() {
        let missing = Fixtures.tempURL(extension: "dat")
        #expect(throws: (any Error).self, "readFrom a missing file") { try Stream(readFrom: missing) }
        #expect(throws: (any Error).self, "update a missing file") { try Stream(update: missing) }
    }

    @Test func streamWithReader() throws {
        #expect(try activeLabel(Stream(data: Fixtures.data(Fixtures.adobeJPEG))) == Fixtures.adobeActiveManifest)
    }

    @Test func streamWithBuilder() throws {
        let output = Fixtures.tempURL(extension: "jpg")
        defer { try? FileManager.default.removeItem(at: output) }
        let builder = try Builder(manifestJSON: Fixtures.createdManifestJSON(claimGenerator: "StreamTest/1.0"))
        let manifest = try builder.sign(
            format: "image/jpeg", source: Fixtures.stream(Fixtures.pexelsJPEG), destination: Stream(writeTo: output),
            signer: Fixtures.signer())
        #expect(!manifest.isEmpty, "sign returns the manifest bytes it embedded")
        #expect(try ManifestStore(json: C2PA.readFile(at: output)).assertionLabels().contains("c2pa.test"))
    }
}

/// A stream operation that fails must fail the signing or reading it serves.
/// The destination's write and flush go through the same adapters as the
/// file-backed streams.
@Suite struct StreamErrorPropagationTests {

    private struct InjectedFailure: Error {}

    private final class MemoryFile {
        var data = Data()
        var position = 0

        func read(_ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
            let available = max(0, min(count, data.count - position))
            if available > 0 {
                data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), from: position..<(position + available))
                position += available
            }
            return available
        }

        func seek(_ offset: Int, from base: Int) -> Int {
            position = max(0, base + offset)
            return position
        }

        func seek(_ offset: Int, origin: UInt32) -> Int {
            switch origin {
            case 0: seek(offset, from: 0)
            case 1: seek(offset, from: position)
            case 2: seek(offset, from: data.count)
            default: -1
            }
        }

        func write(_ bytes: Data) {
            let end = position + bytes.count
            if end > data.count {
                data.append(Data(count: end - data.count))
            }
            data.replaceSubrange(position..<end, with: bytes)
            position = end
        }
    }

    /// A read-only stream over a fixture whose reads fail once `readable` bytes have been delivered.
    private func source(_ name: String, failingAfter readable: Int) throws -> Stream {
        let file = MemoryFile()
        file.data = try Fixtures.data(name)
        var readable = readable
        return try Stream(
            read: { buffer, count in
                guard readable > 0 else { return -1 }
                let delivered = file.read(buffer, min(count, readable))
                readable -= delivered
                return delivered
            },
            seek: { file.seek($0, origin: $1.rawValue) })
    }

    private func sign(
        from source: Stream? = nil,
        into destination: MemoryFile,
        write: @escaping (Data) throws -> Void,
        synchronize: @escaping () throws -> Void
    ) throws {
        let stream = try Stream(
            read: destination.read,
            seek: { destination.seek($0, origin: $1.rawValue) },
            write: Stream.writer(write),
            flush: Stream.flusher(synchronize))
        let builder = try Builder(manifestJSON: Fixtures.createdManifestJSON(claimGenerator: "stream_error_test/1.0"))
        try builder.sign(
            format: "image/jpeg", source: source ?? Fixtures.stream(Fixtures.pexelsJPEG), destination: stream,
            signer: Fixtures.signer())
    }

    @Test func signSucceedsWhenDestinationSucceeds() throws {
        let destination = MemoryFile()
        try sign(into: destination, write: destination.write, synchronize: {})
        let store = try ManifestStore(json: Reader(format: "image/jpeg", stream: Stream(data: destination.data)).json())
        #expect(try store.assertionLabels().contains("c2pa.test"))
    }

    @Test func signFailsWhenDestinationWriteFails() {
        let destination = MemoryFile()
        #expect(throws: C2PAError.self) {
            try sign(into: destination, write: { _ in throw InjectedFailure() }, synchronize: {})
        }
    }

    @Test func signFailsWhenDestinationFlushFails() {
        let destination = MemoryFile()
        #expect(throws: C2PAError.self) {
            try sign(into: destination, write: destination.write, synchronize: { throw InjectedFailure() })
        }
        #expect(!destination.data.isEmpty, "the writes must succeed for the failure to come from the flush")
    }

    /// The source fails after the library has read the asset twice and is
    /// partway through copying it. Reported as the end of the file, that signs
    /// a truncated asset without an error.
    @Test func signFailsWhenSourceReadFails() throws {
        let size = try Fixtures.data(Fixtures.pexelsJPEG).count
        let destination = MemoryFile()
        #expect(throws: C2PAError.self) {
            try sign(
                from: source(Fixtures.pexelsJPEG, failingAfter: size * 5 / 2), into: destination,
                write: destination.write, synchronize: {})
        }
    }

    /// The source fails three quarters of the way through the asset. Reported
    /// as the end of the file, that reads as a manifest that fails validation.
    @Test func readFailsWhenSourceReadFails() throws {
        let size = try Fixtures.data(Fixtures.adobeJPEG).count
        let stream = try source(Fixtures.adobeJPEG, failingAfter: size * 3 / 4)
        #expect(throws: C2PAError.self) { try Reader(format: "image/jpeg", stream: stream) }
    }
}

/// Calls the read and seek callbacks of a file-backed stream directly, on
/// handles the library could not be made to fail on from the outside.
@Suite struct FileStreamCallbackTests {

    private enum Origin: UInt32 {
        case start = 0
        case current = 1
        case end = 2
    }

    private func file(containing text: String) throws -> URL {
        let url = Fixtures.tempURL(extension: "dat")
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Returns what the callback reported and the bytes it delivered.
    private func read(_ reader: Stream.Reader, count: Int) -> (result: Int, text: String) {
        var buffer = [UInt8](repeating: 0, count: count)
        let result = buffer.withUnsafeMutableBytes { reader($0.baseAddress!, count) }
        return (result, String(bytes: buffer.prefix(max(0, result)), encoding: .utf8) ?? "")
    }

    private func seek(_ seeker: Stream.Seeker, _ offset: Int, from origin: Origin) -> Int {
        seeker(offset, .init(rawValue: origin.rawValue))
    }

    @Test func readDeliversTheBytesThenReportsEndOfFile() throws {
        let url = try file(containing: "0123456789")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = Stream.reader(try FileHandle(forReadingFrom: url))

        #expect(read(reader, count: 4) == (4, "0123"))
        #expect(read(reader, count: 16) == (6, "456789"))
        #expect(read(reader, count: 16) == (0, ""))
    }

    /// A handle opened for writing cannot be read, so every read fails.
    @Test func readReportsAFailedReadAsAnError() throws {
        let url = try file(containing: "0123456789")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = Stream.reader(try FileHandle(forWritingTo: url))

        #expect(read(reader, count: 4).result == -1)
    }

    @Test func seekReportsThePositionItMovedTo() throws {
        let url = try file(containing: "0123456789")
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        let seeker = Stream.seeker(handle)

        #expect(seek(seeker, 4, from: .start) == 4)
        #expect(seek(seeker, 3, from: .current) == 7)
        #expect(read(Stream.reader(handle), count: 16) == (3, "789"))
        #expect(seek(seeker, -2, from: .end) == 8)
        #expect(seek(seeker, -100, from: .current) == 0, "a position before the start is clamped to the start")
    }

    /// A pipe has no position to report or move.
    @Test func seekFailsOnAHandleThatCannotSeek() {
        let seeker = Stream.seeker(Pipe().fileHandleForReading)

        #expect(seek(seeker, 0, from: .current) == -1)
        #expect(seek(seeker, 0, from: .start) == -1)
        #expect(seek(seeker, 0, from: .end) == -1)
    }

    @Test func seekFailsWhenThePositionCannotBeRepresented() throws {
        let url = try file(containing: "0123456789")
        defer { try? FileManager.default.removeItem(at: url) }
        let seeker = Stream.seeker(try FileHandle(forReadingFrom: url))

        #expect(seek(seeker, 4, from: .start) == 4)
        #expect(seek(seeker, .max, from: .current) == -1)
        #expect(seek(seeker, .max, from: .end) == -1)
    }

    @Test func positionsAreClampedToTheStartAndRejectedOnOverflow() {
        #expect(Stream.position(4, offsetBy: 3) == 7)
        #expect(Stream.position(4, offsetBy: -3) == 1)
        #expect(Stream.position(4, offsetBy: -100) == 0)
        #expect(Stream.position(4, offsetBy: .max) == nil)
    }

    @Test func seekRejectsAnUnknownOrigin() throws {
        let url = try file(containing: "0123456789")
        defer { try? FileManager.default.removeItem(at: url) }
        let seeker = Stream.seeker(try FileHandle(forReadingFrom: url))

        #expect(seeker(0, .init(rawValue: 7)) == -1)
    }
}
