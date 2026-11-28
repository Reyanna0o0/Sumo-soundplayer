import Foundation
import XCTest
import ResourceAccessSMB
@testable import ResourceAccessAMSMB2

private final class SMBDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SMBDiagnosticEvent] = []
    func receive(_ event: SMBDiagnosticEvent) { lock.lock(); defer { lock.unlock() }; storage.append(event) }
    var events: [SMBDiagnosticEvent] { lock.lock(); defer { lock.unlock() }; return storage }
}

private actor SMBDiagnosticSessionFixture {
    let connectError: NSError?
    let performError: NSError?
    let disconnectError: Error?
    let delayOperation: Bool
    let delayDisconnect: Bool
    var connectCount = 0
    var performCount = 0
    var disconnectCount = 0
    init(connectError: NSError? = nil, performError: NSError? = nil, disconnectError: Error? = nil,
         delayOperation: Bool = false, delayDisconnect: Bool = false) {
        self.connectError = connectError; self.performError = performError; self.disconnectError = disconnectError
        self.delayOperation = delayOperation; self.delayDisconnect = delayDisconnect
    }
    func connect() throws { connectCount += 1; if let connectError { throw connectError } }
    func perform() async throws -> Int {
        performCount += 1
        if delayOperation { try await Task.sleep(nanoseconds: 10_000_000_000) }
        if let performError { throw performError }
        return 42
    }
    func disconnect() async throws {
        disconnectCount += 1
        if delayDisconnect { try await Task.sleep(nanoseconds: 10_000_000_000) }
        if let disconnectError { throw disconnectError }
    }
}

private func exerciseSMBLifecycle(_ fixture: SMBDiagnosticSessionFixture, operation: SMBOperation = .stat,
                                  recorder: SMBDiagnosticRecorder? = nil) async throws -> Int {
    let sink: SMBDiagnosticSink?
    if let recorder { sink = { recorder.receive($0) } } else { sink = nil }
    return try await SMBDiagnosedLifecycle(operation: operation, sink: sink).run(
        connect: { try await fixture.connect() }, perform: { try await fixture.perform() },
        disconnect: { try await fixture.disconnect() })
}

final class SMBDiagnosticsTests: XCTestCase {
    func testEachSuccessfulOperationRecordsItsOwnStageAndStableID() async throws {
        for operation in [SMBOperation.stat, .list, .read] {
            let recorder = SMBDiagnosticRecorder()
            let result = try await exerciseSMBLifecycle(SMBDiagnosticSessionFixture(), operation: operation, recorder: recorder)
            XCTAssertEqual(result, 42)
            let events = recorder.events
            XCTAssertEqual(events.map(\.stage.rawValue), ["connect", "connect", operation.rawValue, operation.rawValue, "disconnect", "disconnect"])
            XCTAssertEqual(events.map(\.outcome), [.started, .succeeded, .started, .succeeded, .started, .succeeded])
            XCTAssertEqual(Set(events.map(\.operationID)).count, 1)
            XCTAssertTrue(events.allSatisfy { $0.operation == operation && $0.elapsedSeconds >= 0 && $0.failure == nil })
        }
    }

    func testSuccessfulReadSurvivesNonCancellationDisconnectFailure() async throws {
        let fixture = SMBDiagnosticSessionFixture(disconnectError: POSIXError(.EPERM))
        let recorder = SMBDiagnosticRecorder()
        let value = try await exerciseSMBLifecycle(fixture, operation: .read, recorder: recorder)
        XCTAssertEqual(value, 42, "A successful read must not be replaced by SDK teardown's generic -1/EPERM")
        let disconnects = await fixture.disconnectCount
        XCTAssertEqual(disconnects, 1, "Do not retry failing teardown on the same closed connection")
        let failure = try XCTUnwrap(recorder.events.last)
        XCTAssertEqual(failure.stage, .disconnect); XCTAssertEqual(failure.outcome, .failed)
        XCTAssertEqual(failure.failure?.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(failure.failure?.code, 1)
        XCTAssertEqual(failure.failure?.reason, .genericOperationFailure)
    }

    func testPrimaryOperationFailureSurvivesCleanupFailure() async throws {
        let primary = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let fixture = SMBDiagnosticSessionFixture(performError: primary, disconnectError: POSIXError(.ETIMEDOUT))
        let recorder = SMBDiagnosticRecorder()
        do { _ = try await exerciseSMBLifecycle(fixture, recorder: recorder); XCTFail("Expected the primary failure") }
        catch { XCTAssertEqual((error as NSError).domain, primary.domain); XCTAssertEqual((error as NSError).code, primary.code) }
        let failures = recorder.events.filter { $0.outcome == .failed }
        XCTAssertEqual(failures.map(\.stage), [.stat, .disconnect])
        XCTAssertEqual(failures.map(\.cleanup), [false, true])
        XCTAssertEqual(failures[0].failure?.code, Int(EACCES)); XCTAssertEqual(failures[1].failure?.code, Int(ETIMEDOUT))
    }

    func testConnectionFailureSkipsOperationAndStillRecordsCleanup() async throws {
        let fixture = SMBDiagnosticSessionFixture(connectError: NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED)))
        let recorder = SMBDiagnosticRecorder()
        do { _ = try await exerciseSMBLifecycle(fixture, operation: .list, recorder: recorder); XCTFail("Expected connect failure") }
        catch { XCTAssertEqual((error as NSError).code, Int(ECONNREFUSED)) }
        let operationCount = await fixture.performCount, disconnects = await fixture.disconnectCount
        XCTAssertEqual(operationCount, 0); XCTAssertEqual(disconnects, 1)
        XCTAssertEqual(recorder.events.map(\.stage), [.connect, .connect, .disconnect, .disconnect])
        XCTAssertTrue(recorder.events.suffix(2).allSatisfy(\.cleanup))
    }

    func testDisconnectCancellationIsNeverConvertedToSuccessfulRead() async {
        let errors: [Error] = [CancellationError(), POSIXError(.ECANCELED), URLError(.cancelled),
            NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError), SMBTransportError.cancelled]
        for error in errors {
            let recorder = SMBDiagnosticRecorder(), fixture = SMBDiagnosticSessionFixture(disconnectError: error)
            do { _ = try await exerciseSMBLifecycle(fixture, operation: .read, recorder: recorder); XCTFail("Cancellation must discard the result") }
            catch { XCTAssertEqual(AMSMB2Transport.transportError(error), .cancelled) }
            XCTAssertEqual(recorder.events.last?.stage, .disconnect)
            XCTAssertEqual(recorder.events.last?.outcome, .failed)
        }
    }

    func testTaskCancellationDuringReadCleansUpAndRetainsCancellation() async {
        let fixture = SMBDiagnosticSessionFixture(disconnectError: POSIXError(.EPERM), delayOperation: true)
        let recorder = SMBDiagnosticRecorder()
        let task = Task { try await exerciseSMBLifecycle(fixture, operation: .read, recorder: recorder) }
        while await fixture.performCount == 0 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled operation must not return bytes") }
        catch { XCTAssertTrue(error is CancellationError) }
        let failures = recorder.events.filter { $0.outcome == .failed }
        XCTAssertEqual(failures.map(\.stage), [.read, .disconnect])
        XCTAssertEqual(failures.first?.failure?.reason, .cancelled)
        XCTAssertEqual(failures.last?.failure?.reason, .genericOperationFailure)
    }

    func testTaskCancellationDuringDisconnectStillDiscardsSuccessfulRead() async {
        let fixture = SMBDiagnosticSessionFixture(delayDisconnect: true), recorder = SMBDiagnosticRecorder()
        let task = Task { try await exerciseSMBLifecycle(fixture, operation: .read, recorder: recorder) }
        while await fixture.disconnectCount == 0 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation is not an ignorable cleanup failure") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(recorder.events.last?.failure?.reason, .cancelled)
    }

    func testDiagnosticsExcludeSecretsAndPreserveSafeUnderlyingReason() async throws {
        let secret = "credential-SECRET@smb-host-SECRET/private-path-SECRET"
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM),
            userInfo: [NSLocalizedDescriptionKey: "Failed to decode packet for \(secret)"])
        let primary = NSError(domain: NSCocoaErrorDomain, code: 513,
            userInfo: [NSLocalizedDescriptionKey: secret, NSFilePathErrorKey: secret,
                       NSUnderlyingErrorKey: underlying])
        let recorder = SMBDiagnosticRecorder()
        do { _ = try await exerciseSMBLifecycle(SMBDiagnosticSessionFixture(performError: primary), recorder: recorder) }
        catch { /* expected */ }
        let event = try XCTUnwrap(recorder.events.first { $0.stage == .stat && $0.outcome == .failed })
        XCTAssertEqual(event.failure?.domain, NSCocoaErrorDomain); XCTAssertEqual(event.failure?.code, 513)
        XCTAssertEqual(event.underlyingFailures.first?.domain, NSPOSIXErrorDomain)
        XCTAssertEqual(event.underlyingFailures.first?.code, Int(EPERM))
        XCTAssertEqual(event.underlyingFailures.first?.reason, .protocolDecode)
        let json = String(decoding: try JSONEncoder().encode(recorder.events), as: UTF8.self)
        XCTAssertFalse(json.contains("SECRET")); XCTAssertFalse(json.contains("private-path"))
        XCTAssertFalse(json.contains("NSLocalizedDescription")); XCTAssertFalse(json.contains("NSFilePath"))
    }

    func testUnknownDomainIsRedactedAndSignatureReasonIsFixedLabel() throws {
        let info = SMBDiagnosticError(NSError(domain: "username.private-host/path-password", code: 13,
            userInfo: [NSLocalizedDescriptionKey: "Invalid signature for smb://username:password@private-host/private-path"]))
        XCTAssertEqual(info.domain, "<redacted-domain>"); XCTAssertTrue(info.domainWasRedacted)
        XCTAssertEqual(info.code, 13); XCTAssertEqual(info.reason, .signatureValidation)
        let json = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        for secret in ["username", "password", "private-host", "private-path"] { XCTAssertFalse(json.contains(secret)) }
    }

    func testGenericEPERMIsDistinctFromAccessDeniedEACCES() {
        XCTAssertEqual(SMBDiagnosticError(POSIXError(.EPERM) as NSError).reason, .genericOperationFailure)
        XCTAssertEqual(SMBDiagnosticError(POSIXError(.EACCES) as NSError).reason, .accessDenied)
        XCTAssertEqual(SMBDiagnosticError(POSIXError(.EPERM) as NSError).code, 1)
        XCTAssertEqual(SMBDiagnosticError(POSIXError(.EACCES) as NSError).code, 13)
    }

    func testConcurrentOperationsHaveIndependentCorrelationIDs() async throws {
        let recorder = SMBDiagnosticRecorder()
        async let first = exerciseSMBLifecycle(SMBDiagnosticSessionFixture(), operation: .stat, recorder: recorder)
        async let second = exerciseSMBLifecycle(SMBDiagnosticSessionFixture(), operation: .read, recorder: recorder)
        let values = try await [first, second]
        XCTAssertEqual(values, [42, 42])
        let grouped = Dictionary(grouping: recorder.events, by: \.operationID)
        XCTAssertEqual(grouped.count, 2)
        XCTAssertTrue(grouped.values.allSatisfy { $0.count == 6 && Set($0.map(\.operation)).count == 1 })
    }

    func testDiagnosticsAreOptionalWithoutChangingLifecycleResult() async throws {
        let fixture = SMBDiagnosticSessionFixture(disconnectError: POSIXError(.EPERM))
        let value = try await exerciseSMBLifecycle(fixture)
        XCTAssertEqual(value, 42)
        let connects = await fixture.connectCount, operations = await fixture.performCount, disconnects = await fixture.disconnectCount
        XCTAssertEqual([connects, operations, disconnects], [1, 1, 1])
    }
}
