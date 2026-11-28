import Foundation
import XCTest
import ResourceAccessCore
@testable import ResourceAccessSMB

private actor SMBFixtureTransport: SMBTransport {
    var info = SMBFileInfo(kind: .regularFile, size: 10, modifiedAt: Date(timeIntervalSince1970: 100))
    var payload = Data("0123456789".utf8)
    var children: [SMBDirectoryItem] = []
    var error: SMBTransportError?
    var changedAfterRead = false
    var readMode = "normal"
    var requests: [SMBRequest] = []
    var readRanges: [ByteRange] = []
    func configure(info: SMBFileInfo? = nil, children: [SMBDirectoryItem]? = nil,
                   error: SMBTransportError? = nil, changed: Bool = false, readMode: String = "normal") {
        if let info { self.info = info }; if let children { self.children = children }
        self.error = error; changedAfterRead = changed; self.readMode = readMode
    }
    func stat(_ request: SMBRequest) throws -> SMBFileInfo {
        requests.append(request); if let error { throw error }; return info
    }
    func listChildren(_ request: SMBRequest) throws -> [SMBDirectoryItem] {
        requests.append(request); if let error { throw error }; return children
    }
    func read(_ request: SMBRequest, range: ByteRange) async throws -> Data {
        requests.append(request); readRanges.append(range)
        if let error { throw error }
        if readMode == "delayed" { try await Task.sleep(nanoseconds: 10_000_000_000) }
        if changedAfterRead { info = SMBFileInfo(kind: .regularFile, size: 10, modifiedAt: Date(timeIntervalSince1970: 101)) }
        if readMode == "short" { return Data() }
        if readMode == "oversized" { return Data(repeating: 1, count: range.length + 1) }
        let start = min(Int(range.offset), payload.count)
        return payload.subdata(in: start..<min(payload.count, start + range.length))
    }
}

final class SMBResourceAdapterTests: XCTestCase {
    private func make(_ transport: SMBFixtureTransport, reference: CredentialReference? = nil,
                      store: InMemoryCredentialStore = InMemoryCredentialStore()) throws -> SMBResourceAdapter {
        let source = try SourceConnection(kind: .smb, endpoint: URL(string: "smb://nas.local:1445/Audio/Selected")!, credentialReference: reference)
        return try SMBResourceAdapter(connection: source, credentialProvider: store, transport: transport)
    }
    private func expect(_ expected: ResourceAccessError, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? ResourceAccessError, expected) }
    }

    func testConfigurationDecodesComponentsOnceAndSeparatesHostShareRoot() throws {
        let source = try SourceConnection(kind: .smb, endpoint: URL(string: "smb://nas.local:1445/Audio%20Share/%E9%9F%B3%E9%A2%91")!)
        let config = try SMBConnectionConfiguration(connection: source, requiresEncryption: true)
        XCTAssertEqual(config.share, "Audio Share"); XCTAssertEqual(config.rootPath.string, "音频")
        XCTAssertEqual(config.serverURL.absoluteString, "smb://nas.local:1445")
        XCTAssertEqual(config.port, 1445); XCTAssertTrue(config.requiresEncryption)
        XCTAssertEqual(try config.shareRelativePath(for: ResourcePath("100%mix/一.mp3")).string, "音频/100%mix/一.mp3")
    }

    func testUnsafeSMBComponentsAreRejected() throws {
        for component in ["..", ".", "a/b", "a\\b", "x:y", "a*", "a?", "nul\0", "a\n", "ending.", "ending "] {
            XCTAssertThrowsError(try SMBConnectionConfiguration.validateComponent(component), component)
        }
        let encodedSlash = try SourceConnection(kind: .smb, endpoint: URL(string: "smb://nas/Audio%2fOther")!)
        XCTAssertThrowsError(try SMBConnectionConfiguration(connection: encodedSlash))
        let wrong = try SourceConnection(kind: .http, endpoint: URL(string: "https://nas/Audio")!)
        XCTAssertThrowsError(try SMBConnectionConfiguration(connection: wrong))
    }

    func testOnlyCredentialReferenceIsSerializableAndRequestsRedactCredentials() async throws {
        let transport = SMBFixtureTransport(), store = InMemoryCredentialStore()
        let reference = CredentialReference("keychain-reference")
        await store.set(.usernamePassword(username: "user-private", password: "secret-private", domain: "WORKGROUP"), for: reference)
        let adapter = try make(transport, reference: reference, store: store)
        _ = try await adapter.metadata(at: ResourcePath("track.mp3"))
        let encoded = String(decoding: try JSONEncoder().encode(adapter.connection), as: UTF8.self)
        XCTAssertTrue(encoded.contains("keychain-reference")); XCTAssertFalse(encoded.contains("secret-private")); XCTAssertFalse(encoded.contains("user-private"))
        let requests = await transport.requests
        XCTAssertFalse(String(describing: requests[0]).contains("secret-private"))
        if case let .usernamePassword(user, password, domain) = requests[0].credential {
            XCTAssertEqual(user, "user-private"); XCTAssertEqual(password, "secret-private"); XCTAssertEqual(domain, "WORKGROUP")
        } else { XCTFail("Transport should receive ephemeral credentials") }
    }

    func testMissingCredentialDoesNotSilentlyFallBackToGuest() async throws {
        let transport = SMBFixtureTransport(), adapter = try make(transport, reference: CredentialReference("missing"))
        await expect(.authorizationRequired) { _ = try await adapter.metadata(at: .root) }
        let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
    }

    func testBearerCredentialIsRejectedForSMB() async throws {
        let transport = SMBFixtureTransport(), store = InMemoryCredentialStore(), reference = CredentialReference()
        await store.set(.bearer("secret"), for: reference)
        let adapter = try make(transport, reference: reference, store: store)
        await expect(.unsupported("SMB requires username/password credentials")) { _ = try await adapter.metadata(at: .root) }
        let requests = await transport.requests; XCTAssertTrue(requests.isEmpty)
    }

    func testBoundedRandomReadPreservesOffsetAndSelectedRoot() async throws {
        let transport = SMBFixtureTransport(), adapter = try make(transport)
        let chunk = try await adapter.read(at: ResourcePath("作品/track.mp3"), range: ByteRange(offset: 4, length: 3))
        XCTAssertEqual(chunk.data, Data("456".utf8)); XCTAssertEqual(chunk.offset, 4); XCTAssertEqual(chunk.totalLength, 10)
        let ranges = await transport.readRanges, requests = await transport.requests
        XCTAssertEqual(ranges, [try ByteRange(offset: 4, length: 3)])
        XCTAssertTrue(requests.allSatisfy { $0.path.string == "Selected/作品/track.mp3" })
        XCTAssertNil(requests.first?.credential)
    }

    func testReadAtEOFSkipsTransportAndReadAcrossEOFReturnsRemainder() async throws {
        let transport = SMBFixtureTransport(), adapter = try make(transport)
        let eof = try await adapter.read(at: ResourcePath("track"), range: ByteRange(offset: 10, length: 2))
        XCTAssertTrue(eof.data.isEmpty)
        let before = await transport.readRanges; XCTAssertTrue(before.isEmpty)
        let tail = try await adapter.read(at: ResourcePath("track"), range: ByteRange(offset: 8, length: 8))
        XCTAssertEqual(tail.data, Data("89".utf8))
    }

    func testExpectedRevisionRejectsChangeBeforeAnyRead() async throws {
        let transport = SMBFixtureTransport(), adapter = try make(transport)
        await expect(.resourceChanged) {
            _ = try await adapter.read(at: ResourcePath("track"), range: ByteRange(offset: 0, length: 3), expectedRevision: ResourceRevision(size: 11))
        }
        let ranges = await transport.readRanges; XCTAssertTrue(ranges.isEmpty)
    }

    func testChangeDuringReadDiscardsTheBytes() async throws {
        let transport = SMBFixtureTransport(), adapter = try make(transport)
        await transport.configure(changed: true)
        await expect(.resourceChanged) { _ = try await adapter.read(at: ResourcePath("track"), range: ByteRange(offset: 0, length: 3)) }
    }

    func testSizeAndMTimeDoNotBecomeAContentIdentity() async throws {
        let transport = SMBFixtureTransport(), adapter = try make(transport)
        let metadata = try await adapter.metadata(at: ResourcePath("track"))
        let chunk = try await adapter.read(at: ResourcePath("track"), range: ByteRange(offset: 0, length: 3), expectedRevision: metadata.revision)
        XCTAssertEqual(chunk.revision.match(metadata.revision), .unknown)
        XCTAssertNil(chunk.revision.contentHash); XCTAssertNil(chunk.revision.etag)
    }

    func testUnexpectedShortAndOversizedReadsFail() async throws {
        let transport = SMBFixtureTransport(), adapter = try make(transport)
        await transport.configure(readMode: "short")
        await expect(.invalidResponse("Unexpected short SMB read")) { _ = try await adapter.read(at: ResourcePath("track"), range: ByteRange(offset: 0, length: 3)) }
        await transport.configure(readMode: "oversized")
        await expect(.invalidResponse("Oversized SMB read")) { _ = try await adapter.read(at: ResourcePath("track"), range: ByteRange(offset: 0, length: 3)) }
    }

    func testImmediateChildrenAreRelativeAndSorted() async throws {
        let transport = SMBFixtureTransport(), adapter = try make(transport)
        await transport.configure(info: SMBFileInfo(kind: .directory), children: [
            SMBDirectoryItem(name: "z.mp3", info: SMBFileInfo(kind: .regularFile, size: 3)),
            SMBDirectoryItem(name: "folder", info: SMBFileInfo(kind: .directory))])
        let entries = try await adapter.listChildren(at: ResourcePath("collection"))
        XCTAssertEqual(entries.map(\.path.string), ["collection/folder", "collection/z.mp3"])
    }

    func testMalformedChildCannotEscapeSelectedRoot() async throws {
        let transport = SMBFixtureTransport(), adapter = try make(transport)
        for name in ["../private", "/absolute", "folder/child", "\\private", "stream:secret"] {
            await transport.configure(info: SMBFileInfo(kind: .directory), children: [SMBDirectoryItem(name: name, info: SMBFileInfo(kind: .regularFile))])
            await expect(.invalidPath("Invalid SMB path component")) { _ = try await adapter.listChildren(at: .root) }
        }
    }

    func testDuplicateChildrenAndLinksAreNotExposed() async throws {
        let transport = SMBFixtureTransport(), adapter = try make(transport)
        let item = SMBDirectoryItem(name: "x", info: SMBFileInfo(kind: .regularFile))
        await transport.configure(info: SMBFileInfo(kind: .directory), children: [item, item])
        await expect(.invalidResponse("Duplicate SMB child name")) { _ = try await adapter.listChildren(at: .root) }
        await transport.configure(info: SMBFileInfo(kind: .symbolicLink))
        await expect(.unsupported("SMB links and special files are not exposed")) { _ = try await adapter.metadata(at: ResourcePath("link")) }
    }

    func testCancellationIsClassifiedAndDoesNotReturnPartialSuccess() async throws {
        let transport = SMBFixtureTransport(), adapter = try make(transport)
        await transport.configure(readMode: "delayed")
        let task = Task { try await adapter.read(at: ResourcePath("track"), range: ByteRange(offset: 0, length: 3)) }
        while await transport.readRanges.isEmpty { await Task.yield() }
        task.cancel()
        await expect(.cancelled) { _ = try await task.value }
    }

    func testTransportErrorClassesRemainDistinct() async throws {
        let transport = SMBFixtureTransport(), adapter = try make(transport)
        let errors: [(SMBTransportError, ResourceAccessError)] = [
            (.authenticationRequired, .authorizationRequired), (.permissionDenied, .permissionDenied),
            (.notFound, .notFound), (.unavailable, .temporarilyUnavailable), (.timedOut, .timedOut),
            (.cancelled, .cancelled), (.resourceChanged, .resourceChanged)]
        for (source, expected) in errors {
            await transport.configure(error: source)
            await expect(expected) { _ = try await adapter.metadata(at: ResourcePath("track")) }
        }
        XCTAssertEqual(classifySMBError(NSError(domain: "private credentials", code: 7)), .invalidResponse("Unclassified SMB operation failure"))
    }

    func testProbeTestsNonzeroOffsetAndNeverPromisesDirectSMBPlayback() async throws {
        let transport = SMBFixtureTransport(), adapter = try make(transport)
        let path = try ResourcePath("track")
        let probe = try await adapter.probe(at: path)
        XCTAssertEqual(probe.playbackAccess, .byteReader(sourceID: adapter.connection.id, path: path))
        XCTAssertEqual(probe.capabilities.directPlayback, .unsupported)
        XCTAssertEqual(probe.capabilities.randomAccess, .supported)
        XCTAssertEqual(probe.capabilities.resumableDownload, .unknown)
        XCTAssertEqual(probe.capabilities.accurateMediaSeek, .unknown)
        let ranges = await transport.readRanges; XCTAssertEqual(ranges.first?.offset, 9)
    }

    func testEmptyFileAndDirectoryDoNotClaimObservedRandomAccess() async throws {
        let transport = SMBFixtureTransport(), adapter = try make(transport)
        await transport.configure(info: SMBFileInfo(kind: .regularFile, size: 0))
        let empty = try await adapter.probe(at: ResourcePath("empty"))
        XCTAssertEqual(empty.capabilities.randomAccess, .unknown)
        await transport.configure(info: SMBFileInfo(kind: .directory))
        let directory = try await adapter.probe(at: .root)
        XCTAssertEqual(directory.playbackAccess, .unavailable)
        let ranges = await transport.readRanges; XCTAssertTrue(ranges.isEmpty)
    }
}
