#if os(macOS)
import Foundation
import XCTest
import ResourceAccessCore
import ResourceAccessHTTP

/// Real URLSession over loopback, with a disposable two-origin Python fixture.
/// Failure to start/bind is a failed test, never a fake protocol pass.
final class HTTPIntegrationTests: XCTestCase {
    private struct Fixture {
        let process: Process
        let directory: URL
        let origin: URL
        let receiver: URL
        func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() }; try? FileManager.default.removeItem(at: directory) }
    }

    private func startFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sumo-http-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info = directory.appendingPathComponent("ports.json")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/protocol_server.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "--port-file", info.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            for _ in 0..<100 {
                if let data = try? Data(contentsOf: info),
                   let values = try JSONSerialization.jsonObject(with: data) as? [String: String],
                   let originString = values["origin"], let origin = URL(string: originString),
                   let receiverString = values["receiver"], let receiver = URL(string: receiverString) {
                    return Fixture(process: process, directory: directory, origin: origin, receiver: receiver)
                }
                guard process.isRunning else { throw ResourceAccessError.invalidConfiguration("Loopback fixture exited before opening its ports") }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw ResourceAccessError.timedOut
        } catch {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func adapter(_ fixture: Fixture, kind: SourceKind = .http) async throws -> HTTPResourceAdapter {
        let store = InMemoryCredentialStore(), reference = CredentialReference("loopback-only")
        await store.set(.usernamePassword(username: "fixture", password: "only-local-test"), for: reference)
        return try HTTPResourceAdapter(connection: SourceConnection(kind: kind, endpoint: fixture.origin, credentialReference: reference, allowsInsecureHTTP: true), credentials: store, timeout: 3)
    }

    func testRealHTTPMetadataRangeUnicodeAndSameOriginRedirect() async throws {
        let fixture = try await startFixture(); defer { fixture.stop() }
        let adapter = try await adapter(fixture)
        let path = try ResourcePath("日本 語 100%.wav")
        let metadata = try await adapter.metadata(at: path)
        XCTAssertEqual(metadata.size, 4096)
        let chunk = try await adapter.read(at: path, range: ByteRange(offset: 257, length: 4), expectedRevision: metadata.revision)
        XCTAssertEqual(chunk.data, Data([1, 2, 3, 4])); XCTAssertEqual(chunk.offset, 257); XCTAssertEqual(chunk.totalLength, 4096)
        let redirect = try await adapter.read(at: ResourcePath("redirect"), range: ByteRange(offset: 513, length: 2), expectedRevision: metadata.revision)
        XCTAssertEqual(redirect.data, Data([1, 2]), "Same-origin redirect must preserve authentication and Range")
    }

    func testRealWebDAVDepthOneAndIgnoredRange() async throws {
        let fixture = try await startFixture(); defer { fixture.stop() }
        let adapter = try await adapter(fixture, kind: .webDAV)
        let entries = try await adapter.listChildren(at: .root)
        XCTAssertEqual(entries.map(\.path.string), ["日本 語 100%.wav", "chosen"])
        XCTAssertTrue(entries[1].metadata.isDirectory)
        await assertAccessError { _ = try await adapter.read(at: ResourcePath("ignored-range"), range: ByteRange(offset: 10, length: 1), expectedRevision: nil) }
        await assertAccessError { _ = try await adapter.metadata(at: ResourcePath("no-head")) }
    }

    func testRealRedirectNeverVisitsOtherOriginWithCredentials() async throws {
        let fixture = try await startFixture(); defer { fixture.stop() }
        let adapter = try await adapter(fixture)
        for name in ["cross-origin", "outside-root"] {
            await assertAccessError { _ = try await adapter.read(at: ResourcePath(name), range: ByteRange(offset: 0, length: 1), expectedRevision: nil) }
        }
        let (data, response) = try await URLSession.shared.data(from: fixture.receiver.appendingPathComponent("metrics"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let metrics = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(metrics["cross_origin_hits"] as? Int, 0)
        XCTAssertTrue(metrics["cross_origin_authorization"] is NSNull)
    }
}
#endif
