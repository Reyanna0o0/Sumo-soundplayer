import Foundation
import Darwin
import XCTest
import AMSMB2
import ResourceAccessCore
import ResourceAccessSMB
@testable import ResourceAccessAMSMB2

private final class SMBLoopbackDiagnosticsCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SMBDiagnosticEvent] = []
    func append(_ event: SMBDiagnosticEvent) { lock.lock(); defer { lock.unlock() }; storage.append(event) }
    var events: [SMBDiagnosticEvent] { lock.lock(); defer { lock.unlock() }; return storage }
}

private struct SMBLoopbackFixture {
    let adapter: SMBResourceAdapter
    let credentials: InMemoryCredentialStore
    let reference: CredentialReference
    let collector: SMBLoopbackDiagnosticsCollector
    let diagnosticsEnabled: Bool
}

final class AMSMB2TransportTests: XCTestCase {
    func testTimeoutIsBounded() throws {
        XCTAssertThrowsError(try AMSMB2Transport(operationTimeout: 0))
        XCTAssertThrowsError(try AMSMB2Transport(operationTimeout: .infinity))
        XCTAssertThrowsError(try AMSMB2Transport(operationTimeout: 121))
        XCTAssertEqual(try AMSMB2Transport(operationTimeout: 3).operationTimeout, 3)
    }
    func testSDKMetadataMappingDoesNotInventHashOrETag() throws {
        let date = Date(timeIntervalSince1970: 100)
        let info = try AMSMB2Transport.fileInfo([.fileResourceTypeKey: URLFileResourceType.regular,
            .fileSizeKey: Int64(42), .contentModificationDateKey: date])
        XCTAssertEqual(info.kind, .regularFile); XCTAssertEqual(info.size, 42)
        XCTAssertEqual(info.modifiedAt, date); XCTAssertNil(info.contentHash)
        XCTAssertEqual(try AMSMB2Transport.fileInfo([.isSymbolicLinkKey: true]).kind, .symbolicLink)
        XCTAssertThrowsError(try AMSMB2Transport.fileInfo([.fileSizeKey: -1]))
    }
    func testPOSIXAndCancellationErrorsAreClassifiedWithoutDescriptions() {
        XCTAssertEqual(AMSMB2Transport.transportError(POSIXError(.EACCES)), .permissionDenied)
        XCTAssertEqual(AMSMB2Transport.transportError(POSIXError(.EAUTH)), .authenticationRequired)
        XCTAssertEqual(AMSMB2Transport.transportError(POSIXError(.ENOENT)), .notFound)
        XCTAssertEqual(AMSMB2Transport.transportError(POSIXError(.ETIMEDOUT)), .timedOut)
        XCTAssertEqual(AMSMB2Transport.transportError(POSIXError(.ECONNREFUSED)), .unavailable)
        XCTAssertEqual(AMSMB2Transport.transportError(CancellationError()), .cancelled)
        XCTAssertEqual(AMSMB2Transport.transportError(NSError(domain: "credential-private", code: 1)), .invalidResponse)
    }

    func testGenericEPERMDoesNotPretendTheServerDeniedAccess() {
        let genericFailure = NSError(domain: NSPOSIXErrorDomain, code: 1)
        let accessDenied = NSError(domain: NSPOSIXErrorDomain, code: 13)
        XCTAssertEqual(AMSMB2Transport.transportError(genericFailure), .invalidResponse)
        XCTAssertEqual(AMSMB2Transport.transportError(accessDenied), .permissionDenied)
        XCTAssertEqual(classifySMBError(AMSMB2Transport.transportError(genericFailure)), .invalidResponse("Invalid SMB response"))
        XCTAssertEqual(classifySMBError(AMSMB2Transport.transportError(accessDenied)), .permissionDenied)
    }

    func testOnlyVerifiedAuthenticationStatusDistinguishesLoginFromNetworkRefusal() {
        let denied = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED),
            userInfo: [SMB2ErrorMetadata.ntStatusKey: NSNumber(value: UInt32(0xC000006D))])
        let unavailable = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))
        let generic = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        XCTAssertEqual(AMSMB2Transport.transportError(denied), .authenticationRequired)
        XCTAssertEqual(SMBDiagnosticError(denied).ntStatus, 0xC000006D)
        XCTAssertEqual(SMBDiagnosticError(denied).reason, .authenticationRejected)
        XCTAssertEqual(AMSMB2Transport.transportError(unavailable), .unavailable)
        XCTAssertNil(SMBDiagnosticError(unavailable).ntStatus)
        XCTAssertEqual(AMSMB2Transport.transportError(generic), .invalidResponse)
        let untrustedDomain = NSError(domain: "not-the-SDK", code: Int(ECONNREFUSED), userInfo: denied.userInfo)
        XCTAssertEqual(AMSMB2Transport.transportError(untrustedDomain), .invalidResponse)
    }

    /// Opt-in local protocol fixture only; never connects to an arbitrary NAS or system share.
    func testLoopbackSMB2ProtocolFixturePositiveReads() async throws {
        let adapter = try await makeFixtureAdapter().adapter
        let children = try await adapter.listChildren(at: .root)
        XCTAssertTrue(children.contains { $0.path.string == "fixture.bin" })
        let path = try ResourcePath("fixture.bin")
        let info = try await adapter.metadata(at: path)
        XCTAssertEqual(info.size, 65_536)
        let chunk = try await adapter.read(at: path, range: ByteRange(offset: 17_003, length: 4097), expectedRevision: info.revision)
        XCTAssertEqual(chunk.data, Data((17_003..<21_100).map { UInt8($0 % 251) }))
        let tail = try await adapter.read(at: path, range: ByteRange(offset: 65_530, length: 30))
        XCTAssertEqual(tail.data.count, 6)
        let probe = try await adapter.probe(at: path)
        XCTAssertEqual(probe.capabilities.directPlayback, .unsupported)
        XCTAssertEqual(probe.capabilities.randomAccess, .supported)
        let unicodePath = try ResourcePath("音频 目录/片段 一.bin")
        let unicode = try await adapter.read(at: unicodePath, range: ByteRange(offset: 251, length: 503))
        XCTAssertEqual(unicode.data, Data((251..<754).map { UInt8($0 % 251) }))
        let unicodeChildren = try await adapter.listChildren(at: ResourcePath("音频 目录"))
        XCTAssertEqual(unicodeChildren.map(\.path.string), ["音频 目录/片段 一.bin"])
    }

    func testLoopbackSMB2ProtocolFixtureMissingAndDenied() async throws {
        let fixture = try await makeFixtureAdapter()
        let adapter = fixture.adapter
        let beforeMissing = fixture.collector.events.count
        do { _ = try await adapter.metadata(at: ResourcePath("missing.bin")); XCTFail("Missing file should fail") }
        catch { XCTAssertEqual(error as? ResourceAccessError, .notFound) }
        try assertStatFailureDiagnostics(fixture, since: beforeMissing, expectedCode: Int(ENOENT))
        let beforeDenied = fixture.collector.events.count
        do { _ = try await adapter.metadata(at: ResourcePath("denied.bin")); XCTFail("Explicit server refusal must remain a real failure") }
        catch { XCTAssertEqual(error as? ResourceAccessError, .permissionDenied) }
        try assertStatFailureDiagnostics(fixture, since: beforeDenied, expectedCode: Int(EACCES))
    }

    func testLoopbackSMB2ProtocolFixtureWrongPasswordClassification() async throws {
        let fixture = try await makeFixtureAdapter()
        await fixture.credentials.set(.usernamePassword(username: "probe", password: "deliberately-wrong"), for: fixture.reference)
        do { _ = try await fixture.adapter.metadata(at: ResourcePath("fixture.bin")); XCTFail("Wrong fixture credential should fail") }
        catch {
            XCTAssertEqual(error as? ResourceAccessError, .authorizationRequired,
                "Verified login rejection must request new credentials")
        }
        let failure = try XCTUnwrap(fixture.collector.events.first { $0.stage == .connect && $0.outcome == .failed })
        XCTAssertEqual(failure.failure?.ntStatus, 0xC000006D)
        XCTAssertEqual(failure.failure?.reason, .authenticationRejected)
        XCTAssertEqual(fixture.collector.events.filter { $0.stage == .connect && $0.outcome == .started }.count, 1,
            "Never retry rejected credentials as guest")
        XCTAssertFalse(fixture.collector.events.contains { $0.stage == .stat }, "Rejected login cannot read as guest")
    }

    func testLoopbackCorrectedCredentialWorksAfterRejectedLogin() async throws {
        let fixture = try await makeFixtureAdapter()
        await fixture.credentials.set(.usernamePassword(username: "probe", password: "deliberately-wrong"), for: fixture.reference)
        do { _ = try await fixture.adapter.metadata(at: ResourcePath("fixture.bin")); XCTFail("Wrong password must fail") }
        catch { XCTAssertEqual(error as? ResourceAccessError, .authorizationRequired) }
        await fixture.credentials.set(.usernamePassword(username: "probe", password: "fixture-only"), for: fixture.reference)
        let boundary = fixture.collector.events.count
        let result = try await fixture.adapter.metadata(at: ResourcePath("fixture.bin"))
        XCTAssertEqual(result.size, 65_536)
        XCTAssertFalse(fixture.collector.events.dropFirst(boundary).contains { $0.outcome == .failed },
            "Rejected login state must not leak into the next authenticated connection or successful disconnect")
    }

    func testLoopbackUnavailablePortIsNotAuthenticationFailure() async throws {
        try requireLoopbackOptIn()
        // Bind without listening: no other service can occupy this unavailable port.
        // The OS may reject immediately or let the SYN time out; neither is authentication.
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        guard bound == 0 else { return }
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &addressLength) }
        }
        XCTAssertEqual(named, 0)
        guard named == 0 else { return }
        let fixture = try await makeFixtureAdapter(port: Int(UInt16(bigEndian: address.sin_port)))
        do { _ = try await fixture.adapter.metadata(at: ResourcePath("fixture.bin")); XCTFail("Unavailable socket must fail") }
        catch {
            let classified = error as? ResourceAccessError
            XCTAssertTrue(classified == .temporarilyUnavailable || classified == .timedOut,
                "Unavailable TCP must be a network error, never an authentication or protocol failure")
        }
        let failure = try XCTUnwrap(fixture.collector.events.first { $0.stage == .connect && $0.outcome == .failed })
        XCTAssertNil(failure.failure?.ntStatus)
        XCTAssertNotEqual(failure.failure?.reason, .authenticationRejected)
        XCTAssertFalse(fixture.collector.events.contains { $0.stage == .stat })
    }

    private func requireLoopbackOptIn() throws {
        guard ProcessInfo.processInfo.environment["SUMO_SMB_LOOPBACK_SMOKE"] == "1" else {
            throw XCTSkip("Requires the explicitly started temporary loopback SMB2 fixture")
        }
    }

    private func makeFixtureAdapter(port requestedPort: Int? = nil) async throws -> SMBLoopbackFixture {
        try requireLoopbackOptIn()
        let port = requestedPort ?? Int(ProcessInfo.processInfo.environment["SUMO_SMB_LOOPBACK_PORT"] ?? "14455") ?? 14455
        guard (1024...65535).contains(port) else { throw ResourceAccessError.invalidConfiguration("Invalid fixture port") }
        let reference = CredentialReference("synthetic-loopback"), credentials = InMemoryCredentialStore()
        await credentials.set(.usernamePassword(username: "probe", password: "fixture-only"), for: reference)
        let source = try SourceConnection(kind: .smb, endpoint: URL(string: "smb://127.0.0.1:\(port)/Probe")!, credentialReference: reference)
        let collector = SMBLoopbackDiagnosticsCollector()
        let diagnosticsEnabled = ProcessInfo.processInfo.environment["SUMO_SMB_DIAGNOSTICS"] == "1"
        let diagnostics: SMBDiagnosticSink = { (event: SMBDiagnosticEvent) in
            collector.append(event)
            if diagnosticsEnabled {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                if let data = try? encoder.encode(event), let text = String(data: data, encoding: .utf8) {
                    print("SMB_DIAGNOSTIC " + text)
                }
            }
        }
        let adapter = try SMBResourceAdapter(connection: source, credentialProvider: credentials,
            transport: AMSMB2Transport(operationTimeout: 5, diagnosticSink: diagnostics))
        return SMBLoopbackFixture(adapter: adapter, credentials: credentials, reference: reference,
            collector: collector, diagnosticsEnabled: diagnosticsEnabled)
    }

    private func assertStatFailureDiagnostics(_ fixture: SMBLoopbackFixture, since start: Int,
                                             expectedCode: Int) throws {
        guard fixture.diagnosticsEnabled else { return }
        let events = Array(fixture.collector.events.dropFirst(start))
        XCTAssertEqual(Set(events.map(\.operationID)).count, 1)
        XCTAssertTrue(events.contains { $0.stage == .connect && $0.outcome == .succeeded })
        let primary = try XCTUnwrap(events.first { $0.stage == .stat && $0.outcome == .failed })
        XCTAssertEqual(primary.failure?.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(primary.failure?.code, expectedCode)
        XCTAssertFalse(primary.cleanup)
        // Cleanup evidence is separate and cannot replace the ENOENT/EACCES above.
        for cleanup in events.filter({ $0.stage == .disconnect && $0.outcome == .failed }) {
            XCTAssertTrue(cleanup.cleanup)
        }
    }
}
