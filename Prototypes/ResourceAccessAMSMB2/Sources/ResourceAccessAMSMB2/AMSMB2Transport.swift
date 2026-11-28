import Foundation
import AMSMB2
import ResourceAccessCore
import ResourceAccessSMB

/// Optional real SMB2/3 backend; it is deliberately not linked into the main App/package.
/// Each operation has its own connection, so cancellation cannot disconnect another source.
public struct AMSMB2Transport: SMBTransport {
    public let operationTimeout: TimeInterval
    private let diagnosticSink: SMBDiagnosticSink?

    public init(operationTimeout: TimeInterval = 15, diagnosticSink: SMBDiagnosticSink? = nil) throws {
        guard operationTimeout.isFinite, operationTimeout > 0, operationTimeout <= 120 else {
            throw ResourceAccessError.invalidConfiguration("SMB timeout must be within 0...120 seconds")
        }
        self.operationTimeout = operationTimeout
        self.diagnosticSink = diagnosticSink
    }

    public func stat(_ request: SMBRequest) async throws -> SMBFileInfo {
        try await connected(request, operationKind: .stat) { manager, _ in
            let attributes = try await manager.attributesOfItem(atPath: request.path.string)
            return try Self.fileInfo(attributes)
        }
    }

    public func listChildren(_ request: SMBRequest) async throws -> [SMBDirectoryItem] {
        try await connected(request, operationKind: .list) { manager, _ in
            // Map inside the callback instead of moving an SDK [String: Any] across actors.
            try await withCheckedThrowingContinuation { continuation in
                manager.contentsOfDirectory(atPath: request.path.string, recursive: false) { result in
                    do {
                        let items = try result.get().map { attributes -> SMBDirectoryItem in
                            guard let name = attributes[.nameKey] as? String else { throw SMBTransportError.invalidResponse }
                            return SMBDirectoryItem(name: name, info: try Self.fileInfo(attributes))
                        }
                        continuation.resume(returning: items)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    public func read(_ request: SMBRequest, range: ByteRange) async throws -> Data {
        try await connected(request, operationKind: .read) { manager, cancellation in
            let bounds = range.offset..<(range.offset + Int64(range.length))
            let data: Data = try await manager.contents(atPath: request.path.string, range: bounds,
                progress: { _, _ in !cancellation.isCancelled })
            guard data.count <= range.length else { throw SMBTransportError.invalidResponse }
            return data
        }
    }

    private func connected<Value: Sendable>(_ request: SMBRequest, operationKind: SMBOperation,
            operation: @Sendable (SMB2Manager, SMBCancellationFlag) async throws -> Value) async throws -> Value {
        let cancellation = SMBCancellationFlag()
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let credential: URLCredential?
                let domain: String
                switch request.credential {
                case let .usernamePassword(username, password, suppliedDomain):
                    credential = URLCredential(user: username, password: password, persistence: .none)
                    domain = suppliedDomain ?? ""
                case .bearer: throw SMBTransportError.unsupported
                case nil: credential = nil; domain = ""
                }
                guard let manager = SMB2Manager(url: request.configuration.serverURL, domain: domain, credential: credential) else {
                    throw SMBTransportError.invalidResponse
                }
                // The SDK can encode its password. Never archive/encode/log this manager.
                manager.timeout = operationTimeout
                let lifecycle = SMBDiagnosedLifecycle(operation: operationKind, sink: diagnosticSink)
                return try await lifecycle.run(
                    connect: { try await manager.connectShare(name: request.configuration.share,
                        encrypted: request.configuration.requiresEncryption) },
                    perform: { try await operation(manager, cancellation) },
                    disconnect: { try await manager.disconnectShare(gracefully: true) })
            } onCancel: {
                // The SDK exposes no per-request immediate cancel. Stop at the next read
                // progress callback and discard late results; a blocked call uses its timeout.
                cancellation.cancel()
            }
        } catch { throw Self.transportError(error) }
    }

    static func fileInfo(_ attributes: [URLResourceKey: Any]) throws -> SMBFileInfo {
        let kind: SMBItemKind
        let type = attributes[.fileResourceTypeKey] as? URLFileResourceType
        if attributes[.isSymbolicLinkKey] as? Bool == true || type == .symbolicLink { kind = .symbolicLink }
        else if attributes[.isDirectoryKey] as? Bool == true || type == .directory { kind = .directory }
        else if attributes[.isRegularFileKey] as? Bool == true || type == .regular { kind = .regularFile }
        else { kind = .other }
        let size = (attributes[.fileSizeKey] as? NSNumber)?.int64Value
        if let size, size < 0 { throw SMBTransportError.invalidResponse }
        return SMBFileInfo(kind: kind, size: size, modifiedAt: attributes[.contentModificationDateKey] as? Date)
    }

    static func transportError(_ error: Error) -> SMBTransportError {
        if error is CancellationError { return .cancelled }
        if let error = error as? SMBTransportError { return error }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain {
            if let status = (error.userInfo[SMB2ErrorMetadata.ntStatusKey] as? NSNumber)?.uint32Value,
               authenticationStatuses.contains(status) {
                return .authenticationRequired
            }
            switch error.code {
            case Int(EAUTH): return .authenticationRequired
            case Int(EACCES): return .permissionDenied
            // The SDK also turns generic service() == -1 into EPERM(1), including
            // protocol/socket failures. Without a verified access-denied status,
            // do not tell the caller that the server rejected its permissions.
            case Int(EPERM): return .invalidResponse
            case Int(ENOENT), Int(ENOTDIR): return .notFound
            case Int(ETIMEDOUT): return .timedOut
            case Int(ECANCELED): return .cancelled
            case Int(ENETDOWN), Int(ENETUNREACH), Int(EHOSTUNREACH), Int(EHOSTDOWN),
                 Int(ECONNREFUSED), Int(ECONNRESET), Int(ENOTCONN), Int(EPIPE): return .unavailable
            case Int(ENOTSUP): return .unsupported
            default: return .invalidResponse
            }
        }
        if error.domain == NSURLErrorDomain {
            if error.code == NSURLErrorCancelled { return .cancelled }
            if error.code == NSURLErrorTimedOut { return .timedOut }
            if error.code == NSURLErrorUserAuthenticationRequired { return .authenticationRequired }
            if [NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet].contains(error.code) { return .unavailable }
        }
        if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError { return .cancelled }
        return .invalidResponse
    }

    /// These are explicit server authentication statuses, never an inference from
    /// a connection phase or a generic POSIX error (LOGON_FAILURE maps to ECONNREFUSED upstream).
    static let authenticationStatuses: Set<UInt32> = [
        0xC0000064, // STATUS_NO_SUCH_USER
        0xC000006A, // STATUS_WRONG_PASSWORD
        0xC000006D, // STATUS_LOGON_FAILURE
        0xC0000071, // STATUS_PASSWORD_EXPIRED
        0xC0000224  // STATUS_PASSWORD_MUST_CHANGE
    ]
}

private final class SMBCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
}
