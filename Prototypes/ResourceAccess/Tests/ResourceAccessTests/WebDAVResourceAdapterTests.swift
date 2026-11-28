import Foundation
import XCTest
import ResourceAccessCore
@testable import ResourceAccessHTTP

final class WebDAVResourceAdapterTests: XCTestCase {
    private func response(_ href: String, directory: Bool = false, extra: String = "") -> String {
        "<d:response><d:href>\(href)</d:href><d:propstat><d:prop><d:resourcetype>\(directory ? "<d:collection/>" : "")</d:resourcetype><d:getcontentlength>12</d:getcontentlength><d:getcontenttype>audio/wav</d:getcontenttype><d:getetag>&quot;v1&quot;</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>\(extra)</d:response>"
    }
    private func document(_ responses: String) -> Data {
        Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><d:multistatus xmlns:d=\"DAV:\">\(responses)</d:multistatus>".utf8)
    }
    private func install(_ data: Data) {
        HTTPMockProtocol.install { _ in .init(status: 207, headers: ["Content-Type": "application/xml", "Content-Length": "\(data.count)"], body: data) }
    }

    func testDepthOneNamespacedListingPreservesUnicodeSpaceAndLiteralPercent() async throws {
        install(document(response("/selected/", directory: true) + response("/selected/%E6%97%A5%E6%9C%AC%20%E8%AA%9E%20100%25.wav") + response("/selected/subdirectory/", directory: true)))
        let entries = try await httpMockAdapter(kind: .webDAV).listChildren(at: .root)
        XCTAssertEqual(entries.map(\.path.string), ["日本 語 100%.wav", "subdirectory"])
        XCTAssertEqual(entries[0].metadata.revision.etag, "\"v1\"")
        XCTAssertFalse(entries[0].metadata.isDirectory); XCTAssertTrue(entries[1].metadata.isDirectory)
        let request = try XCTUnwrap(HTTPMockProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "PROPFIND"); XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "1")
        XCTAssertEqual(HTTPMockProtocol.requests.count, 1, "Enumeration must not recurse automatically")
    }

    func testSubdirectoryListingStaysWithinUserSelectedScope() async throws {
        install(document(response("/selected/chosen/", directory: true) + response("track.wav")))
        let entries = try await httpMockAdapter(kind: .webDAV).listChildren(at: ResourcePath("chosen"))
        XCTAssertEqual(entries.map(\.path.string), ["chosen/track.wav"])
        XCTAssertEqual(HTTPMockProtocol.requests.first?.url?.path, "/selected/chosen")
    }

    func testUnavailableOptionalPropertyDoesNotDiscardSuccessfulResourceType() async throws {
        let optional = "<d:propstat><d:prop><d:getcontentlength/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>"
        install(document(response("/selected/track.wav", extra: optional)))
        let entries = try await httpMockAdapter(kind: .webDAV).listChildren(at: .root)
        XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries[0].metadata.size, 12)
    }

    func testForeignOriginTraversalDeepChildrenAndEncodedSeparatorsAreRejected() async throws {
        let invalid = ["http://other.invalid/selected/file.wav", "/selected-other/file.wav", "../outside/file.wav", "/selected/../selected/file.wav", "/selected/deeper/file.wav", "/selected/%2e%2e/file.wav", "/selected/a%2Fb.wav", "/selected/%252e%252e", "/selected/a%255Cb.wav", "/selected/file.wav?token=secret"]
        for href in invalid {
            install(document(response(href)))
            await assertAccessError { _ = try await httpMockAdapter(kind: .webDAV).listChildren(at: .root) }
        }
    }

    func testDTDExternalEntitiesWrongNamespaceAndMalformedXMLAreRejected() async throws {
        let invalid = [
            "<!DOCTYPE multistatus [<!ENTITY x SYSTEM 'file:///private/secret'>]><d:multistatus xmlns:d='DAV:'>&x;</d:multistatus>",
            "<!DOCTYPE multistatus SYSTEM 'https://elsewhere.invalid/entity'><d:multistatus xmlns:d='DAV:'/>",
            "<d:multistatus xmlns:d='not-DAV'>\(response("/selected/file.wav"))</d:multistatus>",
            "<d:multistatus xmlns:d='DAV:'><d:response>"
        ]
        for xml in invalid {
            install(Data(xml.utf8))
            await assertAccessError { _ = try await httpMockAdapter(kind: .webDAV).listChildren(at: .root) }
        }
        install("<?xml version='1.0' encoding='utf-16'?><d:multistatus xmlns:d='DAV:'/>".data(using: .utf16)!)
        await assertAccessError { _ = try await httpMockAdapter(kind: .webDAV).listChildren(at: .root) }
    }

    func testDuplicateChildAndFailedChildDoNotProducePartialCatalog() async throws {
        install(document(response("/selected/file.wav") + response("/selected/%66ile.wav")))
        await assertAccessError { _ = try await httpMockAdapter(kind: .webDAV).listChildren(at: .root) }
        install(document(response("/selected/good.wav") + "<d:response><d:href>/selected/private.wav</d:href><d:status>HTTP/1.1 403 Forbidden</d:status></d:response>"))
        await assertAccessError(.permissionDenied) { _ = try await httpMockAdapter(kind: .webDAV).listChildren(at: .root) }
    }

    func testEntryAndResponseByteLimitsAreEnforced() async throws {
        let data = document(response("/selected/one.wav") + response("/selected/two.wav"))
        install(data)
        await assertAccessError(.limitExceeded) { _ = try await httpMockAdapter(kind: .webDAV, maximumEntries: 1).listChildren(at: .root) }
        install(data)
        await assertAccessError(.limitExceeded) { _ = try await httpMockAdapter(kind: .webDAV, maximumListingBytes: 20).listChildren(at: .root) }
        HTTPMockProtocol.install { _ in .init(status: 207, body: data) }
        await assertAccessError(.limitExceeded) { _ = try await httpMockAdapter(kind: .webDAV, maximumListingBytes: 20).listChildren(at: .root) }
    }

    func testAuthProbeReturnsByteReaderNotAnUnauthenticatedAVPlayerURL() async throws {
        let store = InMemoryCredentialStore(), reference = CredentialReference("dav-ref")
        await store.set(.bearer("secret"), for: reference)
        HTTPMockProtocol.install { request in
            if request.httpMethod == "HEAD" { return .init(headers: ["Content-Length": "2"]) }
            let offset = request.value(forHTTPHeaderField: "Range") == "bytes=1-1" ? 1 : 0
            return .init(status: 206, headers: ["Content-Range": "bytes \(offset)-\(offset)/2"], body: Data([1]))
        }
        let adapter = try httpMockAdapter(kind: .webDAV, credentialReference: reference, credentials: store)
        let path = try ResourcePath("file.wav"), probe = try await adapter.probe(at: path)
        XCTAssertEqual(probe.playbackAccess, .byteReader(sourceID: adapter.connection.id, path: path))
        XCTAssertEqual(probe.capabilities.directPlayback, .unknown)
    }
}
