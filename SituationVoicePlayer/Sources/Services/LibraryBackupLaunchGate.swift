import Foundation
import CryptoKit

/// Applied before RootView, LibraryStore and preference singletons exist.
/// Large validation happens before the user confirms; the cold-start transaction only renames directories.
enum LibraryBackupLaunchGate {
    struct Pending: Codable { let preparedLeaf: String; let manifestSHA256: String }
    struct Journal: Codable {
        let preparedLeaf: String
        let rollbackLeaf: String
        let hadDocuments: Bool
        let hadSupport: Bool
        var committed: Bool
    }
    enum Result: Equatable { case none, restored, rolledBack, failed(String) }
    static var lastResult: Result = .none
    private static let pendingName = "pending.json", journalName = "journal.json"

    static func confirm(_ prepared: LibraryBackupCore.Prepared, roots: LibraryBackupRoots) throws {
        try validateLocation(prepared.directory, roots: roots)
        // A caller cannot bypass content validation by retaining a stale Prepared value.
        let manifestData = try Data(contentsOf: prepared.directory.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(LibraryBackupManifest.self, from: manifestData)
        guard manifest == prepared.manifest else { throw LibraryBackupError.invalid("备份准备状态已改变") }
        let payload = prepared.directory.appendingPathComponent("payload", isDirectory: true)
        let actual = try LibraryBackupCore.inventory(payload, prefix: "payload", limits: .init())
        let paths = Set(actual.map { String($0.0.dropFirst("payload/".count)) })
        guard paths == Set(manifest.files.map(\.path)) else { throw LibraryBackupError.invalid("暂存文件已改变") }
        for file in manifest.files {
            try LibraryBackupCore.checkCancellation()
            let url = payload.appendingPathComponent(file.path)
            guard try LibraryBackupCore.regularFileSize(url) == file.bytes,
                  try hashFile(url) == file.sha256 else { throw LibraryBackupError.invalid("暂存文件完整性检查失败") }
        }
        guard try LibraryBackupCore.validateDatabase(payload.appendingPathComponent("Documents/hibiki.db")) == manifest.databaseSchema else {
            throw LibraryBackupError.invalid("暂存数据库无效")
        }
        try LibraryBackupCore.validateOwnedSourceManifest(manifest, payload: payload)
        try LibraryBackupCore.validateRestoredReferences(manifest, payload: payload)
        _ = try LibraryBackupPreferences.decode(Data(contentsOf: payload.appendingPathComponent("preferences.plist")))
        let pending = Pending(preparedLeaf: prepared.directory.lastPathComponent,
                              manifestSHA256: LibraryBackupCore.hex(SHA256.hash(data: manifestData)))
        guard !FileManager.default.fileExists(atPath: roots.state.appendingPathComponent(journalName).path) else {
            throw LibraryBackupError.invalid("另一次恢复尚未结束")
        }
        try write(pending, at: roots.state.appendingPathComponent(pendingName))
    }

    static func hasPending(roots: LibraryBackupRoots) -> Bool {
        FileManager.default.fileExists(atPath: roots.state.appendingPathComponent(pendingName).path)
    }
    static func cancelPending(roots: LibraryBackupRoots) throws {
        let file = roots.state.appendingPathComponent(pendingName)
        guard !FileManager.default.fileExists(atPath: roots.state.appendingPathComponent(journalName).path) else {
            throw LibraryBackupError.invalid("恢复正在执行")
        }
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let pending = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: file))
        guard validLeaf(pending.preparedLeaf, prefix: "prepared-") else { throw LibraryBackupError.invalid("待恢复标记无效") }
        let prepared = roots.state.appendingPathComponent(pending.preparedLeaf, isDirectory: true)
        if FileManager.default.fileExists(atPath: prepared.path) { try validateLocation(prepared, roots: roots) }
        // Remove only the staged payload named by this pending operation; never a rollback library.
        if FileManager.default.fileExists(atPath: prepared.path) { try FileManager.default.removeItem(at: prepared) }
        try FileManager.default.removeItem(at: file)
    }

    @discardableResult
    static func applyPendingRestoreBeforeAppInitialization() -> Result {
        do {
            let result = try apply(roots: .application(), defaults: .standard)
            lastResult = result; return result
        } catch {
            let result = Result.failed(error.localizedDescription)
            lastResult = result; return result
        }
    }

    /// Injected checkpoints are only used by synthetic tests, never App settings.
    static func apply(roots: LibraryBackupRoots, defaults: UserDefaults,
                      checkpoint: ((String) throws -> Void)? = nil) throws -> Result {
        try LibraryBackupCore.ensureDirectory(roots.state)
        let fm = FileManager.default, journalURL = roots.state.appendingPathComponent(journalName)
        if fm.fileExists(atPath: journalURL.path) {
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
            try validateJournal(journal)
            if journal.committed { try finish(journal, roots: roots); return .restored }
            try rollback(journal, roots: roots, defaults: defaults)
            return .rolledBack
        }
        let pendingURL = roots.state.appendingPathComponent(pendingName)
        guard fm.fileExists(atPath: pendingURL.path) else { return .none }
        let pending = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: pendingURL))
        guard validLeaf(pending.preparedLeaf, prefix: "prepared-") else { throw LibraryBackupError.invalid("待恢复标记无效") }
        let prepared = roots.state.appendingPathComponent(pending.preparedLeaf, isDirectory: true)
        try validateLocation(prepared, roots: roots)
        let manifestData = try Data(contentsOf: prepared.appendingPathComponent("manifest.json"))
        guard LibraryBackupCore.hex(SHA256.hash(data: manifestData)) == pending.manifestSHA256 else {
            throw LibraryBackupError.invalid("待恢复清单已改变")
        }
        let manifest = try JSONDecoder().decode(LibraryBackupManifest.self, from: manifestData)
        let payload = prepared.appendingPathComponent("payload", isDirectory: true)
        try LibraryBackupCore.ensureDirectory(payload.appendingPathComponent("Documents"))
        try LibraryBackupCore.ensureDirectory(payload.appendingPathComponent("ApplicationSupport"))
        let newPreferences = try LibraryBackupPreferences.decode(Data(contentsOf: payload.appendingPathComponent("preferences.plist")))
        let rollbackLeaf = "rollback-" + UUID().uuidString
        let rollbackRoot = roots.state.appendingPathComponent(rollbackLeaf, isDirectory: true)
        try LibraryBackupCore.ensureDirectory(rollbackRoot)
        let oldPreferences = try LibraryBackupPreferences.data(from: defaults.dictionaryRepresentation())
        try oldPreferences.write(to: rollbackRoot.appendingPathComponent("preferences.plist"), options: .atomic)
        var journal = Journal(preparedLeaf: pending.preparedLeaf, rollbackLeaf: rollbackLeaf,
            hadDocuments: fm.fileExists(atPath: roots.documents.path),
            hadSupport: fm.fileExists(atPath: roots.applicationSupport.path), committed: false)
        try write(journal, at: journalURL)
        do {
            try checkpoint?("journalPersisted")
            if journal.hadDocuments { try fm.moveItem(at: roots.documents, to: rollbackRoot.appendingPathComponent("Documents")) }
            try checkpoint?("oldDocumentsMoved")
            try fm.moveItem(at: payload.appendingPathComponent("Documents"), to: roots.documents)
            try checkpoint?("newDocumentsMoved")
            if journal.hadSupport { try fm.moveItem(at: roots.applicationSupport, to: rollbackRoot.appendingPathComponent("ApplicationSupport")) }
            try checkpoint?("oldSupportMoved")
            try fm.moveItem(at: payload.appendingPathComponent("ApplicationSupport"), to: roots.applicationSupport)
            try checkpoint?("newSupportMoved")
            try LibraryBackupCore.reanchorOwnedSources(roots.documents.appendingPathComponent("hibiki.db"), manifest: manifest, roots: roots)
            LibraryBackupPreferences.apply(newPreferences, to: defaults)
            guard defaults.synchronize() else { throw LibraryBackupError.invalid("偏好设置保存失败") }
            try checkpoint?("preferencesApplied")
            journal.committed = true
            try write(journal, at: journalURL)
        } catch {
            // Keep the journal if rollback itself fails: the next cold start retries it.
            try rollback(journal, roots: roots, defaults: defaults)
            throw error
        }
        // A committed journal remains recoverable if this housekeeping is interrupted.
        try finish(journal, roots: roots)
        return .restored
    }

    private static func rollback(_ journal: Journal, roots: LibraryBackupRoots, defaults: UserDefaults) throws {
        try validateJournal(journal)
        let fm = FileManager.default, old = roots.state.appendingPathComponent(journal.rollbackLeaf)
        let payload = roots.state.appendingPathComponent(journal.preparedLeaf).appendingPathComponent("payload")
        for (name, target, hadOriginal) in [("Documents", roots.documents, journal.hadDocuments),
                                          ("ApplicationSupport", roots.applicationSupport, journal.hadSupport)] {
            let saved = old.appendingPathComponent(name)
            if fm.fileExists(atPath: saved.path) {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: saved, to: target)
            } else if !hadOriginal && !fm.fileExists(atPath: payload.appendingPathComponent(name).path) {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            }
        }
        let preferences = try LibraryBackupPreferences.decode(Data(contentsOf: old.appendingPathComponent("preferences.plist")))
        LibraryBackupPreferences.apply(preferences, to: defaults)
        guard defaults.synchronize() else { throw LibraryBackupError.invalid("回滚偏好设置失败") }
        let pending = roots.state.appendingPathComponent(pendingName)
        if fm.fileExists(atPath: pending.path) { try fm.removeItem(at: pending) }
        try fm.removeItem(at: roots.state.appendingPathComponent(journalName))
        let prepared = roots.state.appendingPathComponent(journal.preparedLeaf)
        if fm.fileExists(atPath: prepared.path) { try? fm.removeItem(at: prepared) }
    }
    private static func finish(_ journal: Journal, roots: LibraryBackupRoots) throws {
        let fm = FileManager.default
        try write(["rollbackLeaf": journal.rollbackLeaf], at: roots.state.appendingPathComponent("last-successful-restore.json"))
        let pending = roots.state.appendingPathComponent(pendingName)
        if fm.fileExists(atPath: pending.path) { try fm.removeItem(at: pending) }
        try fm.removeItem(at: roots.state.appendingPathComponent(journalName))
        let prepared = roots.state.appendingPathComponent(journal.preparedLeaf)
        if fm.fileExists(atPath: prepared.path) { try? fm.removeItem(at: prepared) }
        // Original directories remain in rollback-UUID; no automatic deletion of the prior library.
    }
    private static func validateJournal(_ journal: Journal) throws {
        guard validLeaf(journal.preparedLeaf, prefix: "prepared-"), validLeaf(journal.rollbackLeaf, prefix: "rollback-") else {
            throw LibraryBackupError.invalid("恢复事务标记无效")
        }
    }
    private static func validLeaf(_ value: String, prefix: String) -> Bool {
        value.hasPrefix(prefix) && UUID(uuidString: String(value.dropFirst(prefix.count))) != nil
    }
    private static func validateLocation(_ directory: URL, roots: LibraryBackupRoots) throws {
        guard directory.deletingLastPathComponent().standardizedFileURL == roots.state.standardizedFileURL,
              validLeaf(directory.lastPathComponent, prefix: "prepared-") else { throw LibraryBackupError.invalid("暂存目录无效") }
        guard FileManager.default.fileExists(atPath: directory.path) else { throw LibraryBackupError.invalid("暂存目录无效") }
        try LibraryBackupCore.ensureDirectory(directory)
    }
    static func hashFile(_ url: URL) throws -> String {
        let handle = try LibraryBackupCore.readHandle(url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: LibraryBackupCore.chunkSize), !data.isEmpty {
            try LibraryBackupCore.checkCancellation(); hash.update(data: data)
        }
        return LibraryBackupCore.hex(hash.finalize())
    }
    private static func write<T: Encodable>(_ value: T, at url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
