import XCTest
import Foundation
import CryptoKit
@testable import ResourceAccessCore

final class CoreResourceTests: XCTestCase {
    private let identity = TrackIdentity(workID: 7, trackID: 11)
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sumo-core-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func adapter(_ data: Data = Data("test audio bytes".utf8)) throws -> CoreMemoryAdapter {
        CoreMemoryAdapter(connection: try SourceConnection(kind: .http, endpoint: URL(string: "https://example.invalid/chosen/")!), data: data)
    }
    private func location(_ adapter: CoreMemoryAdapter) throws -> ResourceLocation {
        .init(sourceID: adapter.connection.id, path: try ResourcePath("作品/01 音声.wav"))
    }

    func testPathRejectsTraversalAndPreservesUnicodeAsLiteralComponents() throws {
        for input in ["/absolute", "../secret", "a/../b", "a//b", "a/./b", "a\\b", "a\0b"] {
            XCTAssertThrowsError(try ResourcePath(input), input)
        }
        let path = try ResourcePath("社团/100% 空格 #?.wav")
        let url = path.url(relativeTo: URL(string: "https://example.invalid/root/")!)
        XCTAssertEqual(url.path, "/root/社团/100% 空格 #?.wav")
        XCTAssertNil(url.query); XCTAssertNil(url.fragment)
        XCTAssertEqual(try JSONDecoder().decode(ResourcePath.self, from: JSONEncoder().encode(path)), path)
        XCTAssertThrowsError(try JSONDecoder().decode(ResourcePath.self, from: Data("\"../escape\"".utf8)))
    }
    func testConnectionValidationAlsoRunsWhenDecodingPersistedConfiguration() throws {
        XCTAssertThrowsError(try SourceConnection(kind: .http, endpoint: URL(string: "http://example.invalid/")!))
        XCTAssertThrowsError(try SourceConnection(kind: .smb, endpoint: URL(string: "smb://user:secret@host/share/")!))
        let allowed = try SourceConnection(kind: .http, endpoint: URL(string: "http://127.0.0.1:18080/root/")!, allowsInsecureHTTP: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(allowed)) as? [String: Any])
        object["allowsInsecureHTTP"] = false
        XCTAssertThrowsError(try JSONDecoder().decode(SourceConnection.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    func testCredentialReferencesDoNotSerializeSecrets() async throws {
        let store = InMemoryCredentialStore(), reference = CredentialReference()
        await store.set(.usernamePassword(username: "fixture-user", password: "fixture-private-secret"), for: reference)
        let connection = try SourceConnection(kind: .webDAV, endpoint: URL(string: "https://example.invalid/dav/")!, credentialReference: reference)
        let encoded = String(decoding: try JSONEncoder().encode(connection), as: UTF8.self)
        XCTAssertFalse(encoded.contains("fixture-private-secret")); XCTAssertFalse(encoded.contains("fixture-user"))
        let stored = await store.credential(for: reference)
        let credential = try XCTUnwrap(stored)
        XCTAssertEqual(String(describing: credential), "ResourceCredential(<redacted>)")
    }
    func testByteRangeLimitsPreventOverflowAndUnboundedReads() throws {
        XCTAssertThrowsError(try ByteRange(offset: -1, length: 1))
        XCTAssertThrowsError(try ByteRange(offset: 0, length: 0))
        XCTAssertThrowsError(try ByteRange(offset: 0, length: ByteRange.maximumLength + 1))
        XCTAssertThrowsError(try ByteRange(offset: Int64.max, length: 1))
        XCTAssertEqual(try ByteRange(offset: 10, length: 4).lastOffset, 13)
    }
    func testWeakMetadataAndCrossServerETagsDoNotProveIdentity() {
        let date = Date(timeIntervalSince1970: 123)
        XCTAssertEqual(ResourceRevision(size: 8, modifiedAt: date).match(.init(size: 8, modifiedAt: date)), .unknown)
        XCTAssertEqual(ResourceRevision(size: 8, etag: "W/\"a\"").match(.init(size: 8, etag: "W/\"a\"")), .unknown)
        XCTAssertEqual(ResourceRevision(etag: "\"a\"").match(.init(etag: "\"a\"")), .same)
        XCTAssertEqual(ResourceRevision(etag: "\"a\"").contentMatchAcrossLocations(.init(etag: "\"a\"")), .unknown)
        XCTAssertEqual(ResourceRevision(contentHash: "hash").contentMatchAcrossLocations(.init(contentHash: "hash")), .same)
        XCTAssertEqual(ResourceRevision(size: 8).match(.init(size: 9)), .different)
    }
    func testRemovingConnectionPreservesStableBindingAndSnapshot() async throws {
        let adapter = try adapter(), catalog = ResourceCatalog()
        let binding = ResourceBinding(identity: identity, locations: [try location(adapter)])
        await catalog.register(adapter); await catalog.bind(binding)
        await catalog.removeConnection(adapter.connection.id)
        let retained = await catalog.binding(for: identity)
        XCTAssertEqual(retained, binding)
        do { _ = try await catalog.resolve(identity, expectedRevision: nil); XCTFail("Disconnected source must not resolve") }
        catch { XCTAssertEqual(error as? ResourceAccessError, .temporarilyUnavailable) }
        let restored = ResourceCatalog()
        try await restored.restore(JSONDecoder().decode(ResourceCatalogSnapshot.self, from: JSONEncoder().encode(await catalog.snapshot())))
        let restoredBinding = await restored.binding(for: identity)
        XCTAssertEqual(restoredBinding, binding)
    }
    func testCompleteCopySurvivesSourceRemovalAndStoreReopen() async throws {
        let directory = try temporaryDirectory(), adapter = try adapter()
        let location = try location(adapter), store = try OwnedResourceStore(directory: directory)
        let record = try await store.copy(from: adapter, location: location, identity: identity, byteLimit: 100, chunkSize: 3)
        XCTAssertEqual(record.revision.contentHash?.count, 64)
        let reopened = try OwnedResourceStore(directory: directory), catalog = ResourceCatalog(ownedFiles: reopened)
        await catalog.register(adapter); await catalog.bind(.init(identity: identity, locations: [location]))
        await catalog.removeConnection(adapter.connection.id)
        let resolved = try await catalog.resolve(identity, expectedRevision: nil)
        XCTAssertEqual(resolved.identity, identity); XCTAssertEqual(resolved.probe.residency, .applicationOwnedComplete)
        guard case .localFile(let url) = resolved.probe.playbackAccess else { return XCTFail("Expected a complete owned file") }
        XCTAssertEqual(try Data(contentsOf: url), Data("test audio bytes".utf8))
    }
    func testPartialCopyIsNotPlayableAndCancellationCleansStaging() async throws {
        let directory = try temporaryDirectory(), adapter = try adapter()
        await adapter.blockNextRead()
        let store = try OwnedResourceStore(directory: directory), location = try location(adapter)
        let task = Task { try await store.copy(from: adapter, location: location, identity: identity, byteLimit: 100) }
        await adapter.waitForBlockedRead()
        let during = try await store.resolve(identity)
        XCTAssertNil(during)
        task.cancel(); await adapter.releaseRead()
        do { _ = try await task.value; XCTFail("Cancelled copy cannot publish") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        let after = try await store.resolve(identity)
        XCTAssertNil(after)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".partial-") })
    }
    func testNewerCopySupersedesOlderOperationWithoutOverwritingNewResult() async throws {
        let directory = try temporaryDirectory(), older = try adapter(Data("OLD".utf8)), newer = try adapter(Data("NEW".utf8))
        let store = try OwnedResourceStore(directory: directory), oldLocation = try location(older), newLocation = try location(newer)
        await older.blockNextRead()
        let oldTask = Task { try await store.copy(from: older, location: oldLocation, identity: identity, byteLimit: 100) }
        await older.waitForBlockedRead()
        let newRecord = try await store.copy(from: newer, location: newLocation, identity: identity, byteLimit: 100)
        await older.releaseRead()
        do { _ = try await oldTask.value; XCTFail("Superseded copy cannot publish") }
        catch { XCTAssertEqual(error as? ResourceAccessError, .cancelled) }
        let current = await store.record(for: identity)
        XCTAssertEqual(current, newRecord)
    }
    func testTruncatedAndChangedCopiesNeverPublishOfflineState() async throws {
        for mode in [CoreMemoryAdapter.Mode.truncated, .changed] {
            let directory = try temporaryDirectory(), adapter = try adapter()
            await adapter.setMode(mode)
            let store = try OwnedResourceStore(directory: directory)
            do { _ = try await store.copy(from: adapter, location: location(adapter), identity: identity, byteLimit: 100); XCTFail("Bad copy published") }
            catch { XCTAssertTrue(error is ResourceAccessError) }
            let record = await store.record(for: identity)
            XCTAssertNil(record)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".partial-") })
        }
    }
    func testSizeLimitStopsBeforeReadingAudioBody() async throws {
        let adapter = try adapter(), store = try OwnedResourceStore(directory: temporaryDirectory())
        do { _ = try await store.copy(from: adapter, location: location(adapter), identity: identity, byteLimit: 1); XCTFail("Exceeded size limit") }
        catch { XCTAssertEqual(error as? ResourceAccessError, .limitExceeded) }
        let reads = await adapter.readCount
        XCTAssertEqual(reads, 0)
    }
    func testRebindingDoesNotSelectOldOfflineFileAtUnverifiedNewSource() async throws {
        let old = try adapter(), new = try adapter(Data("new version".utf8)), store = try OwnedResourceStore(directory: temporaryDirectory())
        _ = try await store.copy(from: old, location: location(old), identity: identity, byteLimit: 100)
        let catalog = ResourceCatalog(ownedFiles: store)
        await catalog.register(new)
        let newLocation = try location(new)
        await catalog.bind(.init(identity: identity, locations: [newLocation]))
        let resolved = try await catalog.resolve(identity, expectedRevision: nil)
        XCTAssertEqual(resolved.location, newLocation)
        XCTAssertEqual(resolved.probe.residency, .remote)
    }
    func testTamperedOfflineIndexCannotEscapeOwnedDirectory() throws {
        let directory = try temporaryDirectory()
        let record = OwnedCopyRecord(identity: identity, origin: .init(sourceID: UUID(), path: .root), fileName: "../outside.wav", revision: .init(size: 1))
        try JSONEncoder().encode([record]).write(to: directory.appendingPathComponent("index.json"))
        XCTAssertThrowsError(try OwnedResourceStore(directory: directory))
    }
    func testWeakRevisionCannotPublishAnUnverifiedMultiRangeCopy() async throws {
        let adapter = try adapter(), store = try OwnedResourceStore(directory: temporaryDirectory())
        await adapter.setMode(.weak)
        do { _ = try await store.copy(from: adapter, location: location(adapter), identity: identity, byteLimit: 100, chunkSize: 3); XCTFail("Weak ranges must not publish") }
        catch ResourceAccessError.unsupported {} catch { XCTFail("Unexpected \(error)") }
        let reads = await adapter.readCount
        XCTAssertEqual(reads, 0)
    }
    func testMissingRangeValidatorCannotUseInitialETagAsProof() async throws {
        let adapter = try adapter(), store = try OwnedResourceStore(directory: temporaryDirectory())
        await adapter.setMode(.missingRangeValidator)
        do { _ = try await store.copy(from: adapter, location: location(adapter), identity: identity, byteLimit: 100, chunkSize: 3); XCTFail("Unknown range version must not publish") }
        catch ResourceAccessError.unsupported {} catch { XCTFail("Unexpected \(error)") }
        let saved = await store.record(for: identity)
        XCTAssertNil(saved)
    }
    func testExpectedHashVerifiesWeakCopyAndRejectsDifferentBytes() async throws {
        let data = Data("test audio bytes".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        for expected in [hash, String(repeating: "0", count: 64)] {
            let adapter = try adapter(data), store = try OwnedResourceStore(directory: temporaryDirectory())
            await adapter.setMode(.weak)
            let location = ResourceLocation(sourceID: adapter.connection.id, path: try ResourcePath("file.wav"), expectedRevision: .init(contentHash: expected))
            if expected == hash {
                let saved = try await store.copy(from: adapter, location: location, identity: identity, byteLimit: 100, chunkSize: 3)
                XCTAssertEqual(saved.revision.contentHash, hash)
            } else {
                do { _ = try await store.copy(from: adapter, location: location, identity: identity, byteLimit: 100, chunkSize: 3); XCTFail("Wrong expected hash must not publish") }
                catch { XCTAssertEqual(error as? ResourceAccessError, .resourceChanged) }
                let saved = await store.record(for: identity)
                XCTAssertNil(saved)
            }
        }
    }
    func testSameSizeCacheCorruptionCannotSupplyOldIdentityHash() async throws {
        let directory = try temporaryDirectory(), adapter = try adapter(Data("OLD".utf8))
        let store = try OwnedResourceStore(directory: directory)
        let record = try await store.copy(from: adapter, location: location(adapter), identity: identity, byteLimit: 100)
        try Data("NEW".utf8).write(to: directory.appendingPathComponent(record.fileName))
        let resolved = try await store.resolve(identity)
        XCTAssertNil(resolved)
    }
    func testLateProbeCannotResolveAfterRebindDisconnectOrReregister() async throws {
        for change in 0..<3 {
            let adapter = try adapter(), catalog = ResourceCatalog()
            let original = try location(adapter)
            await catalog.register(adapter); await catalog.bind(.init(identity: identity, locations: [original]))
            await adapter.blockNextProbe()
            let task = Task { try await catalog.resolve(identity, expectedRevision: nil) }
            await adapter.waitForBlockedRead()
            if change == 0 { await catalog.bind(.init(identity: identity, locations: [])) }
            else if change == 1 { await catalog.disconnect(adapter.connection.id) }
            else { await catalog.register(adapter) }
            await adapter.releaseRead()
            do { _ = try await task.value; XCTFail("Stale probe must not resolve") }
            catch { XCTAssertEqual(error as? ResourceAccessError, .cancelled) }
        }
    }
}

private actor CoreMemoryAdapter: ResourceAdapter {
    enum Mode { case normal, truncated, changed, weak, missingRangeValidator }
    let connection: SourceConnection
    let data: Data
    private var mode: Mode = .normal
    private var shouldBlock = false
    private var shouldBlockProbe = false
    private var gate: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private(set) var readCount = 0
    init(connection: SourceConnection, data: Data) { self.connection = connection; self.data = data }
    func setMode(_ mode: Mode) { self.mode = mode }
    func blockNextRead() { shouldBlock = true }
    func blockNextProbe() { shouldBlockProbe = true }
    func waitForBlockedRead() async { if gate != nil { return }; await withCheckedContinuation { observer = $0 } }
    func releaseRead() { gate?.resume(); gate = nil }
    func metadata(at path: ResourcePath) -> ResourceMetadata { .init(size: Int64(data.count), revision: .init(size: Int64(data.count), etag: mode == .weak ? nil : "\"fixture-v1\"")) }
    func listChildren(at path: ResourcePath) -> [ResourceEntry] { [] }
    func probe(at path: ResourcePath) async -> ResourceProbe {
        if shouldBlockProbe {
            shouldBlockProbe = false
            await withCheckedContinuation { continuation in gate = continuation; observer?.resume(); observer = nil }
        }
        return .init(metadata: metadata(at: path), residency: .remote,
              capabilities: .init(sequentialRead: .supported, randomAccess: .supported),
              playbackAccess: .byteReader(sourceID: connection.id, path: path))
    }
    func read(at path: ResourcePath, range: ByteRange, expectedRevision: ResourceRevision?) async -> ResourceChunk {
        readCount += 1
        if shouldBlock {
            shouldBlock = false
            await withCheckedContinuation { continuation in gate = continuation; observer?.resume(); observer = nil }
        }
        let lo = min(data.count, Int(range.offset)), hi = min(data.count, lo + range.length)
        let bytes = data.subdata(in: lo..<hi)
        return .init(data: mode == .truncated ? Data(bytes.dropLast()) : bytes, offset: range.offset,
                     totalLength: Int64(data.count), revision: .init(size: Int64(data.count), etag: mode == .weak || mode == .missingRangeValidator ? nil : (mode == .changed ? "\"fixture-v2\"" : "\"fixture-v1\"")))
    }
}
