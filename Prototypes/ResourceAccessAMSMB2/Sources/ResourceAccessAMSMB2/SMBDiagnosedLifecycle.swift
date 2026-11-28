import Foundation
import ResourceAccessSMB

/// Keeps diagnostic/error ordering independently testable without a network or SDK manager.
/// Disconnect failure never replaces an earlier connect/operation failure.
struct SMBDiagnosedLifecycle: Sendable {
    let operation: SMBOperation
    let sink: SMBDiagnosticSink?

    func run<Value>(connect: () async throws -> Void,
                    perform: () async throws -> Value,
                    disconnect: () async throws -> Void) async throws -> Value {
        let diagnostics = SMBOperationDiagnostics(operation: operation, sink: sink)
        var disconnectAttempted = false
        do {
            try await diagnostics.stage(.connect) {
                try Task.checkCancellation()
                try await connect()
                try Task.checkCancellation()
            }
            let stage: SMBStage
            switch operation { case .stat: stage = .stat; case .list: stage = .list; case .read: stage = .read }
            let value = try await diagnostics.stage(stage) {
                try Task.checkCancellation()
                let result = try await perform()
                try Task.checkCancellation()
                return result
            }
            disconnectAttempted = true
            do {
                try await diagnostics.stage(.disconnect) {
                    try await disconnect()
                    try Task.checkCancellation()
                }
            } catch {
                // A stat/list/read result already succeeded. A non-cancellation close
                // failure is still diagnosed, but must not turn those bytes/metadata
                // into a misleading permission error. This policy is read-only.
                if Self.isCancellation(error) { throw error }
                if Task.isCancelled { throw CancellationError() }
            }
            return value
        } catch {
            let primaryFailure = error
            if !disconnectAttempted {
                // Cleanup deliberately runs even when the task is cancelled. It is recorded
                // independently and its failure cannot hide the primary failing stage.
                do { try await diagnostics.stage(.disconnect, cleanup: true) { try await disconnect() } }
                catch { /* already captured as a separate cleanup diagnostic */ }
            }
            throw primaryFailure
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let transportError = error as? SMBTransportError, transportError == .cancelled { return true }
        let error = error as NSError
        return (error.domain == NSPOSIXErrorDomain && error.code == Int(ECANCELED)) ||
            (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) ||
            (error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError)
    }
}
