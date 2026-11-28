import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import ResourceAccessCore
@testable import ResourceAccessHTTP

final class HTTPResourceAdapterTests: XCTestCase {
    func testMetadataAndCredentialReferenceDoNotPutSecretsInURL() async throws {
        let store = InMemoryCredentialStore(), reference = CredentialReference("test-reference")
        await store.set(.usernamePassword(username: "test", password: "secret"), for: reference)
        HTTPMockProtocol.install { _ in .init(headers: ["Content-Length": "120", "ETag": "\"v1\"", "Content-Type": "audio/wav"]) }
        let adapter = try httpMockAdapter(credentialReference: reference, credentials: store)
        let result = try await adapter.metadata(at: ResourcePath("日本 語 100%.wav"))
        XCTAssertEqual(result.size, 120); XCTAssertEqual(result.revision.etag, "\"v1\"")
        let request = try XCTUnwrap(HTTPMockProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "HEAD")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dGVzdDpzZWNyZXQ=")
        XCTAssertNil(request.url?.user); XCTAssertFalse(request.url!.absoluteString.contains("secret"))
        XCTAssertTrue(request.url!.absoluteString.contains("%25.wav"))
        XCTAssertEqual(request.url?.lastPathComponent, "日本 語 100%.wav")
    }

    func testRangeChecksOffsetsLengthTotalAndVersion() async throws {
        HTTPMockProtocol.install { _ in .init(status: 206, headers: ["Content-Range": "bytes 4-7/20", "Content-Length": "4", "ETag": "\"v1\""], body: Data([4, 5, 6, 7])) }
        let chunk = try await httpMockAdapter().read(at: ResourcePath("audio.wav"), range: ByteRange(offset: 4, length: 4), expectedRevision: .init(size: 20, etag: "\"v1\""))
        XCTAssertEqual(chunk.data, Data([4, 5, 6, 7])); XCTAssertEqual(chunk.offset, 4); XCTAssertEqual(chunk.totalLength, 20)
        XCTAssertEqual(HTTPMockProtocol.requests.first?.value(forHTTPHeaderField: "Range"), "bytes=4-7")
        XCTAssertEqual(HTTPMockProtocol.requests.first?.value(forHTTPHeaderField: "If-Range"), "\"v1\"")
    }

    func testValidShortRangeAtEOF() async throws {
        HTTPMockProtocol.install { _ in .init(status: 206, headers: ["Content-Range": "bytes 18-19/20"], body: Data([18, 19])) }
        let result = try await httpMockAdapter().read(at: ResourcePath("end.mp3"), range: ByteRange(offset: 18, length: 5), expectedRevision: nil)
        XCTAssertEqual(result.data.count, 2); XCTAssertEqual(result.totalLength, 20)
    }

    func testIgnoredRangeNeverBecomesRandomAccess() async throws {
        HTTPMockProtocol.install { request in
            .init(status: 200, headers: ["Content-Length": "1000000000", "Accept-Ranges": "bytes"], body: request.httpMethod == "HEAD" ? Data() : Data(repeating: 1, count: 8192))
        }
        let result = try await httpMockAdapter().probe(at: ResourcePath("large.wav"))
        XCTAssertEqual(result.capabilities.randomAccess, .unsupported)
        XCTAssertEqual(result.capabilities.accurateMediaSeek, .unknown)
        XCTAssertEqual(result.residency, .remote)
    }

    func testValidByteRangeDoesNotClaimAccurateMediaSeekOrOfflineCopy() async throws {
        HTTPMockProtocol.install { request in
            if request.httpMethod == "HEAD" { return .init(headers: ["Content-Length": "20"]) }
            let offset = request.value(forHTTPHeaderField: "Range") == "bytes=19-19" ? 19 : 0
            return .init(status: 206, headers: ["Content-Range": "bytes \(offset)-\(offset)/20"], body: Data([1]))
        }
        let result = try await httpMockAdapter().probe(at: ResourcePath("media.m4a"))
        XCTAssertEqual(result.capabilities.randomAccess, .supported)
        XCTAssertEqual(result.capabilities.accurateMediaSeek, .unknown)
        XCTAssertEqual(result.capabilities.resumableDownload, .unknown)
        XCTAssertEqual(result.capabilities.completeDownload, .unknown)
        XCTAssertEqual(HTTPMockProtocol.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=19-19")
    }

    func testOneByteFileDoesNotProveNonzeroRandomAccess() async throws {
        HTTPMockProtocol.install { request in
            request.httpMethod == "HEAD" ? .init(headers: ["Content-Length": "1"]) : .init(status: 206, headers: ["Content-Range": "bytes 0-0/1"], body: Data([1]))
        }
        let result = try await httpMockAdapter().probe(at: ResourcePath("one"))
        XCTAssertEqual(result.capabilities.sequentialRead, .supported)
        XCTAssertEqual(result.capabilities.randomAccess, .unknown)
    }

    func testMalformedOrMismatchedContentRangeFails() async throws {
        for header in ["bytes 3-6/20", "bytes 4-9/20", "bytes 4-7/7", "bytes 4-7/*", "bytes 7-4/20", "items 4-7/20", "bytes +4-7/20"] {
            HTTPMockProtocol.install { _ in .init(status: 206, headers: ["Content-Range": header], body: Data([1, 2, 3, 4])) }
            await assertAccessError { _ = try await httpMockAdapter().read(at: ResourcePath("x"), range: ByteRange(offset: 4, length: 4), expectedRevision: nil) }
        }
    }

    func testHeaderBodyLengthAndEncodingAreChecked() async throws {
        let replies: [HTTPMockProtocol.Reply] = [
            .init(status: 206, headers: ["Content-Range": "bytes 4-7/20", "Content-Length": "5"], body: Data([1, 2, 3, 4])),
            .init(status: 206, headers: ["Content-Range": "bytes 4-7/20"], body: Data([1, 2, 3])),
            .init(status: 206, headers: ["Content-Range": "bytes 4-7/20"], body: Data([1, 2, 3, 4, 5])),
            .init(status: 206, headers: ["Content-Range": "bytes 4-7/20", "Content-Encoding": "gzip"], body: Data([1, 2, 3, 4]))
        ]
        for reply in replies {
            HTTPMockProtocol.install { _ in reply }
            await assertAccessError { _ = try await httpMockAdapter().read(at: ResourcePath("x"), range: ByteRange(offset: 4, length: 4), expectedRevision: nil) }
        }
    }

    func testChangedFileIsNotJoinedToOldVersion() async throws {
        HTTPMockProtocol.install { _ in .init(status: 206, headers: ["Content-Range": "bytes 0-0/21", "ETag": "\"v2\""], body: Data([1])) }
        await assertAccessError(.resourceChanged) {
            _ = try await httpMockAdapter().read(at: ResourcePath("x"), range: ByteRange(offset: 0, length: 1), expectedRevision: .init(size: 20, etag: "\"v1\""))
        }
    }

    func testErrorClassification() async throws {
        for (status, error) in [(401, ResourceAccessError.authorizationRequired), (403, .permissionDenied), (404, .notFound), (429, .temporarilyUnavailable), (500, .temporarilyUnavailable), (503, .temporarilyUnavailable), (504, .timedOut)] {
            HTTPMockProtocol.install { _ in .init(status: status) }
            await assertAccessError(error) { _ = try await httpMockAdapter().metadata(at: ResourcePath("x")) }
        }
        HTTPMockProtocol.install { _ in .init(error: URLError(.timedOut)) }
        await assertAccessError(.timedOut) { _ = try await httpMockAdapter().metadata(at: ResourcePath("x")) }
    }

    func testCancellationPropagatesWithoutWaitingForBody() async throws {
        HTTPMockProtocol.install { _ in .init(headers: ["Content-Length": "20"], delay: 5) }
        let adapter = try httpMockAdapter()
        let task = Task { try await adapter.metadata(at: ResourcePath("x")) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        await assertAccessError(.cancelled) { _ = try await task.value }
    }

    func testHTTPDirectoryEnumerationAndMissingCredentialAreNotInvented() async throws {
        await assertAccessError { _ = try await httpMockAdapter().listChildren(at: .root) }
        let reference = CredentialReference("missing")
        await assertAccessError(.authorizationRequired) { _ = try await httpMockAdapter(credentialReference: reference).metadata(at: ResourcePath("x")) }
    }
}
