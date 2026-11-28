import Foundation
import Combine

@MainActor
final class LibraryBackupCoordinator: ObservableObject {
    static let shared = LibraryBackupCoordinator()
    @Published private(set) var isBusy = false
    @Published private(set) var restoreReady = false
    @Published private(set) var message: String?
    @Published private(set) var progress: Double = 0
    @Published private(set) var prepared: LibraryBackupCore.Prepared?
    /// Synchronous gate: Combine's willSet publication can run observers before `isBusy` has changed.
    private(set) var playbackLocked = false
    private var operationID = UUID()
    private var cancelWork: (() -> Void)?

    private init() {
        if let roots = try? LibraryBackupRoots.application() {
            restoreReady = LibraryBackupLaunchGate.hasPending(roots: roots)
            playbackLocked = restoreReady
            if case .failed = LibraryBackupLaunchGate.lastResult { return }
            // Capture before any new operation can create its own UUID. Only deletion is asynchronous.
            if let captured = try? LibraryBackupCore.captureInterruptedWork(roots: roots), !captured.isEmpty {
                Task.detached(priority: .utility) {
                    LibraryBackupCore.removeCapturedInterruptedWork(captured, roots: roots)
                }
            }
        }
    }
    func report(_ text: String) { message = InterfaceLocalization.key(text) }
    func cancelOperation() { cancelWork?() }
    func clearMessage() { message = nil }

    func export() async -> URL? {
        guard !isBusy, !restoreReady else { return nil }
        playbackLocked = true
        isBusy = true; progress = 0; message = nil
        defer { finishOperation() }
        do {
            let roots = try LibraryBackupRoots.application()
            let preferences = try LibraryBackupPreferences.data(from: UserDefaults.standard.dictionaryRepresentation())
            let output = roots.state.appendingPathComponent("Exports", isDirectory: true)
                .appendingPathComponent("Simo-\(UUID().uuidString).simobackup")
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let reporter = makeProgressReporter()
            let task = Task.detached(priority: .userInitiated) {
                try LibraryBackupCore.export(roots: roots, preferences: preferences, destination: output,
                    appVersion: version, progress: reporter)
            }
            cancelWork = { task.cancel() }
            _ = try await task.value
            // Preference edits from an already-running task must also invalidate the package.
            let current = try LibraryBackupPreferences.data(from: UserDefaults.standard.dictionaryRepresentation())
            let before = try LibraryBackupPreferences.decode(preferences) as NSDictionary
            let after = try LibraryBackupPreferences.decode(current) as NSDictionary
            guard before.isEqual(after) else {
                try? FileManager.default.removeItem(at: output)
                throw LibraryBackupError.changedDuringBackup
            }
            progress = 1
            return output
        } catch { reportFailure(error); return nil }
    }

    func prepareRestore(from url: URL) async {
        guard !isBusy, !restoreReady else { return }
        playbackLocked = true
        discardPrepared(); isBusy = true; progress = 0; message = nil
        defer { finishOperation() }
        do {
            let roots = try LibraryBackupRoots.application()
            let reporter = makeProgressReporter()
            let task = Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                var coordinationError: NSError?
                var result: Result<LibraryBackupCore.Prepared, Error>?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
                    result = Result { try LibraryBackupCore.prepareRestore(archiveURL: coordinated, roots: roots,
                                                                           progress: reporter) }
                }
                if let coordinationError { throw coordinationError }
                guard let result else { throw CocoaError(.fileReadUnknown) }
                return try result.get()
            }
            cancelWork = { task.cancel() }
            prepared = try await task.value; progress = 1
        } catch { reportFailure(error) }
    }

    func confirmRestore() async {
        guard !isBusy, !restoreReady, let prepared else { return }
        playbackLocked = true
        isBusy = true; progress = 0; message = nil
        defer { finishOperation() }
        do {
            let roots = try LibraryBackupRoots.application()
            let task = Task.detached(priority: .userInitiated) { try LibraryBackupLaunchGate.confirm(prepared, roots: roots) }
            cancelWork = { task.cancel() }
            try await task.value
            self.prepared = nil; restoreReady = true
        } catch { reportFailure(error) }
    }
    func discardPrepared() {
        guard !isBusy else { return }
        if let prepared { try? FileManager.default.removeItem(at: prepared.directory) }
        prepared = nil
    }
    func cancelPendingRestore() {
        guard !isBusy else { return }
        do {
            try LibraryBackupLaunchGate.cancelPending(roots: .application())
            // Observers of the false publication must see the released synchronous gate.
            // PlayerController's published lock remains held until that publication arrives.
            playbackLocked = false
            restoreReady = false
            report("已取消待恢复操作，当前资料未被替换。")
        } catch { reportFailure(error) }
    }
    func removeExport(_ url: URL) {
        guard let roots = try? LibraryBackupRoots.application(),
              url.deletingLastPathComponent() == roots.state.appendingPathComponent("Exports", isDirectory: true) else { return }
        try? FileManager.default.removeItem(at: url)
    }
    private func reportFailure(_ error: Error) {
        message = error is CancellationError ? InterfaceLocalization.text("操作已取消。") : error.localizedDescription
    }
    private func finishOperation() {
        // All file/database work has finished. Release the synchronous gate before publishing
        // false so lock-screen observers can re-enable commands using the current state.
        // Their published lock remains held until this final notification; pending restore stays locked.
        cancelWork = nil
        playbackLocked = restoreReady
        isBusy = false
    }
    private func makeProgressReporter() -> @Sendable (Int64, Int64) -> Void {
        let id = UUID(); operationID = id
        let throttle = LibraryBackupProgressThrottle()
        return { [weak self] completed, total in
            guard let fraction = throttle.fractionIfDue(completed: completed, total: total) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.operationID == id, self.isBusy else { return }
                self.progress = max(self.progress, fraction)
            }
        }
    }
}
