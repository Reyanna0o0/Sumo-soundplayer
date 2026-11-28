import Foundation
import AMSMB2
import ResourceAccessCore
import ResourceAccessSMB

public enum SMBOperation: String, Codable, Sendable { case stat, list, read }
public enum SMBStage: String, Codable, Sendable { case connect, stat, list, read, disconnect }
public enum SMBStageOutcome: String, Codable, Sendable { case started, succeeded, failed }

/// Fixed labels only. These are heuristic classifications, not verbatim SDK messages.
public enum SMBSafeFailureReason: String, Codable, Sendable {
    case signatureValidation, signingFailure, protocolDecode, authenticationRejected, invalidFileDescriptor
    case accessDenied, genericOperationFailure, notFound, timedOut, cancelled, connectionUnavailable, unsupported, unknown
}

public struct SMBDiagnosticError: Codable, Equatable, Sendable {
    /// Original NSError domain when it is a known framework/type domain; otherwise redacted.
    public let domain: String
    public let code: Int
    public let domainWasRedacted: Bool
    public let reason: SMBSafeFailureReason
    public let ntStatus: UInt32?

    init(_ error: NSError) {
        let allowedDomains: Set<String> = [NSPOSIXErrorDomain, NSCocoaErrorDomain, NSURLErrorDomain,
            NSOSStatusErrorDomain, "kCFErrorDomainCFNetwork", "kCFErrorDomainPOSIX",
            "ResourceAccessSMB.SMBTransportError", "ResourceAccessCore.ResourceAccessError", "Swift.CancellationError"]
        domainWasRedacted = !allowedDomains.contains(error.domain)
        domain = domainWasRedacted ? "<redacted-domain>" : error.domain
        code = error.code
        ntStatus = (error.userInfo[SMB2ErrorMetadata.ntStatusKey] as? NSNumber)?.uint32Value
        reason = Self.safeReason(error)
    }

    private static func safeReason(_ error: NSError) -> SMBSafeFailureReason {
        if error.domain == NSPOSIXErrorDomain,
           let status = (error.userInfo[SMB2ErrorMetadata.ntStatusKey] as? NSNumber)?.uint32Value,
           AMSMB2Transport.authenticationStatuses.contains(status) { return .authenticationRejected }
        // Inspect only for fixed phrases. Never retain, interpolate, or emit the raw text.
        let text = (error.userInfo[NSLocalizedDescriptionKey] as? String).map { String($0.prefix(4096)).lowercased() } ?? ""
        if text.contains("bad file descriptor") || text.contains("read from socket failed, errno:9") {
            return .invalidFileDescriptor
        }
        if text.contains("signature") && ["mismatch", "invalid", "does not match", "verification failed", "verify failed", "failed to verify", "wrong signature"].contains(where: text.contains) {
            return .signatureValidation
        }
        if text.contains("signing") && ["failed", "failure", "mismatch", "invalid"].contains(where: text.contains) {
            return .signingFailure
        }
        if ["failed to decode", "decode failed", "decoding failed", "malformed packet", "invalid packet",
            "invalid pdu", "unexpected response", "protocol error", "buffer too small"].contains(where: text.contains) {
            return .protocolDecode
        }
        if ["status_logon_failure", "logon failure", "authentication failed", "authentication failure"].contains(where: text.contains) {
            return .authenticationRejected
        }
        if error.domain == NSPOSIXErrorDomain {
            switch error.code {
            case Int(EAUTH): return .authenticationRejected
            case Int(EACCES): return .accessDenied
            // libsmb2 service() may return generic -1; the SDK then presents POSIX 1.
            // That number alone cannot establish that the server denied permissions.
            case Int(EPERM): return .genericOperationFailure
            case Int(ENOENT), Int(ENOTDIR): return .notFound
            case Int(ETIMEDOUT): return .timedOut
            case Int(ECANCELED): return .cancelled
            case Int(ENETDOWN), Int(ENETUNREACH), Int(EHOSTUNREACH), Int(EHOSTDOWN), Int(ECONNREFUSED),
                 Int(ECONNRESET), Int(ENOTCONN), Int(EPIPE): return .connectionUnavailable
            case Int(ENOTSUP): return .unsupported
            default: break
            }
        }
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorCancelled: return .cancelled
            case NSURLErrorTimedOut: return .timedOut
            case NSURLErrorUserAuthenticationRequired: return .authenticationRejected
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet: return .connectionUnavailable
            default: break
            }
        }
        if error.domain == "Swift.CancellationError" { return .cancelled }
        return .unknown
    }
}

public struct SMBDiagnosticEvent: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let operation: SMBOperation
    public let stage: SMBStage
    public let outcome: SMBStageOutcome
    /// True only for disconnect attempted after a primary connect/operation failure.
    public let cleanup: Bool
    public let elapsedSeconds: TimeInterval
    public let failure: SMBDiagnosticError?
    /// A bounded chain of NSError domain/code/fixed-reason triples; no userInfo or descriptions.
    public let underlyingFailures: [SMBDiagnosticError]
}

public typealias SMBDiagnosticSink = @Sendable (SMBDiagnosticEvent) -> Void

struct SMBOperationDiagnostics: Sendable {
    let operationID = UUID()
    let operation: SMBOperation
    let sink: SMBDiagnosticSink?

    func stage<Value>(_ stage: SMBStage, cleanup: Bool = false,
                      body: () async throws -> Value) async throws -> Value {
        let start = ProcessInfo.processInfo.systemUptime
        emit(stage, outcome: .started, cleanup: cleanup, elapsed: 0, error: nil)
        do {
            let value = try await body()
            emit(stage, outcome: .succeeded, cleanup: cleanup,
                 elapsed: ProcessInfo.processInfo.systemUptime - start, error: nil)
            return value
        } catch {
            emit(stage, outcome: .failed, cleanup: cleanup,
                 elapsed: ProcessInfo.processInfo.systemUptime - start, error: error)
            throw error
        }
    }

    private func emit(_ stage: SMBStage, outcome: SMBStageOutcome, cleanup: Bool,
                      elapsed: TimeInterval, error: Error?) {
        guard let sink else { return }
        let nsError = error.map { $0 as NSError }
        var underlying: [SMBDiagnosticError] = []
        var visited = Set<ObjectIdentifier>()
        if let nsError { visited.insert(ObjectIdentifier(nsError)) }
        var next = nsError?.userInfo[NSUnderlyingErrorKey] as? NSError
        while let current = next, underlying.count < 3, visited.insert(ObjectIdentifier(current)).inserted {
            underlying.append(SMBDiagnosticError(current))
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        sink(SMBDiagnosticEvent(operationID: operationID, operation: operation, stage: stage,
            outcome: outcome, cleanup: cleanup, elapsedSeconds: max(0, elapsed),
            failure: nsError.map(SMBDiagnosticError.init), underlyingFailures: underlying))
    }
}
