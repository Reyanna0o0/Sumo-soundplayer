import Foundation
import CryptoKit
import SQLite3
import ZIPFoundation
import Darwin
#if canImport(HibikiCore)
import HibikiCore
#endif

/// Portable backup format. Only App-owned files are included; external sources are references.
struct LibraryBackupManifest: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable { let path: String; let bytes: Int64; let sha256: String }
    struct ExternalSource: Codable, Equatable, Sendable {
        let name: String
        let kind: String
        let mediaIncluded: Bool
        let availability: String
    }
    struct OwnedSource: Codable, Equatable, Sendable { let id: Int64; let originalRoot: String; let payloadRoot: String }
    let ownedSources: [OwnedSource]
    let format: String
    let version: Int
    let createdAt: Date
    let appVersion: String
    let databaseSchema: Int
    let files: [File]
    let externalSources: [ExternalSource]
    let externalMediaPolicy: String
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

struct LibraryBackupRoots: Sendable {
    let documents: URL
    let applicationSupport: URL
    /// Must be outside both backed-up folders. Never exposed through File Sharing.
    let state: URL
    static func application() throws -> Self {
        let fm = FileManager.default
        let documents = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return Self(documents: documents, applicationSupport: support,
                    state: support.deletingLastPathComponent().appendingPathComponent("SumoLibraryBackupState", isDirectory: true))
    }
}

enum LibraryBackupError: LocalizedError {
    case invalid(String), insufficientSpace, unsupportedSchema, changedDuringBackup, cancelled
    var errorDescription: String? {
        switch self {
        case .invalid(let reason):
            #if os(iOS)
            return InterfaceLocalization.text("备份无法使用：\(InterfaceLocalization.key(reason))")
            #else
            return "备份无法使用：\(reason)"
            #endif
        case .insufficientSpace: return backupText("本机可用空间不足，请先留出备份或恢复所需的空间。")
        case .unsupportedSchema: return backupText("备份的数据版本不受当前厮磨支持，请使用相同或更新的兼容版本。")
        case .changedDuringBackup: return backupText("备份期间资料发生变化，请停止编辑或导入后重新备份。")
        case .cancelled: return backupText("操作已取消。")
        }
    }
}

struct LibraryBackupLimits: Sendable {
    var maximumFiles = 200_000
    var maximumBytes: Int64 = 512 * 1024 * 1024 * 1024
    var manifestBytes: Int64 = 32 * 1024 * 1024
    var preferencesBytes: Int64 = 16 * 1024 * 1024
    var freeSpaceReserve: Int64 = 256 * 1024 * 1024
}

/// A separate instance per operation bounds UI updates to at most 101, before any actor task is created.
final class LibraryBackupProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1
    func fractionIfDue(completed: Int64, total: Int64) -> Double? {
        guard total > 0 else { return nil }
        let percent = min(100, max(0, Int(Double(completed) / Double(total) * 100)))
        lock.lock(); defer { lock.unlock() }
        guard percent > lastPercent else { return nil }
        lastPercent = percent
        return Double(percent) / 100
    }
}

/// Explicit keys/prefixes; never serialize the entire UserDefaults domain or Keychain.
enum LibraryBackupPreferences {
    static let keys: Set<String> = ["appAppearancePalette", "appInterfaceLanguage", "obscureWorkCovers",
        "selectedMediaLibrary", "openingVoiceSelection.v1", "subtitleQuickDrafts.v1", "library.collectionWorkDisplay",
        "hibiki.call.realisticControlLabels", "hibiki.call.subtitleInMiddle", "hibiki.playback.speakerProtection",
        "hibiki.subtitle.modeStyles.v1", "hibiki.subtitle.pictureInPicture", "hibiki.subtitle.style"]
    static let prefixes = ["stats.", "library.workSort.", "library.customWorkOrder.", "library.directoryOrder.", "importedZIPCopies."]
    static func permits(_ key: String) -> Bool {
        let lower = key.lowercased()
        guard !["password", "secret", "credential", "token", "keychain"].contains(where: lower.contains) else { return false }
        return keys.contains(key) || prefixes.contains(where: key.hasPrefix)
    }
    static func data(from values: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: values.filter { permits($0.key) }, format: .binary, options: 0)
    }
    static func decode(_ data: Data) throws -> [String: Any] {
        guard let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              values.keys.allSatisfy(permits) else { throw LibraryBackupError.invalid("偏好设置包含不支持的内容") }
        return values
    }
    static func apply(_ values: [String: Any], to defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where permits(key) { defaults.removeObject(forKey: key) }
        for (key, value) in values where permits(key) { defaults.set(value, forKey: key) }
    }
}

/// No live database handle is replaced. Export uses SQLite's consistent VACUUM INTO snapshot.
enum LibraryBackupCore {
    static let currentSchema = Schema.currentVersion
    static let chunkSize = 1024 * 1024
    static let externalPolicy = "外部文件夹和 NAS 音频不包含在备份中；只保留来源记录。来源可用性未验证，恢复后可能需要重新授权、关联或输入密码。"
    struct Prepared: Sendable {
        let id: UUID
        let directory: URL
        let manifest: LibraryBackupManifest
    }
    struct InterruptedWorkDirectory: Sendable {
        let url: URL
        let identity: String
    }

    /// Only enumerate immediate children here. The startup thread never walks a media tree.
    static func captureInterruptedWork(roots: LibraryBackupRoots) throws -> [InterruptedWorkDirectory] {
        guard directoryIdentity(roots.state) != nil, !hasRestoreMarkers(roots: roots) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: roots.state, includingPropertiesForKeys: nil)
            .compactMap { url in
                guard isInterruptedWorkName(url.lastPathComponent), let identity = directoryIdentity(url) else { return nil }
                return InterruptedWorkDirectory(url: url, identity: identity)
            }
    }

    /// Call on a background worker with the startup snapshot, never rescan after an operation begins.
    /// Exports, rollback libraries, new UUID directories, symlinks and replaced directories are untouched.
    @discardableResult
    static func removeCapturedInterruptedWork(_ captured: [InterruptedWorkDirectory], roots: LibraryBackupRoots) -> Int {
        guard directoryIdentity(roots.state) != nil, !hasRestoreMarkers(roots: roots) else { return 0 }
        var removed = 0
        for item in captured {
            guard !hasRestoreMarkers(roots: roots) else { break }
            guard item.url.deletingLastPathComponent().standardizedFileURL == roots.state.standardizedFileURL,
                  isInterruptedWorkName(item.url.lastPathComponent), directoryIdentity(item.url) == item.identity else { continue }
            do { try FileManager.default.removeItem(at: item.url); removed += 1 }
            catch { /* Leave inaccessible temporary data for a later launch; never touch library targets. */ }
        }
        return removed
    }
    private static func isInterruptedWorkName(_ name: String) -> Bool {
        guard let prefix = ["export-", "prepared-"].first(where: name.hasPrefix) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        return suffix.count == 36 && UUID(uuidString: suffix)?.uuidString.caseInsensitiveCompare(suffix) == .orderedSame
    }
    private static func directoryIdentity(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }
    private static func hasRestoreMarkers(roots: LibraryBackupRoots) -> Bool {
        ["pending.json", "journal.json"].contains { name in
            var info = stat()
            // Even a malformed or dangling-link marker prevents automatic deletion.
            return lstat(roots.state.appendingPathComponent(name).path, &info) == 0
        }
    }

    static func export(roots: LibraryBackupRoots, preferences: Data, destination: URL,
                       appVersion: String, limits: LibraryBackupLimits = .init(),
                       progress: (@Sendable (Int64, Int64) -> Void)? = nil) throws -> LibraryBackupManifest {
        try checkCancellation()
        _ = try LibraryBackupPreferences.decode(preferences)
        guard preferences.count <= limits.preferencesBytes else { throw LibraryBackupError.invalid("偏好设置过大") }
        try ensureDirectory(roots.state)
        let work = roots.state.appendingPathComponent("export-" + UUID().uuidString, isDirectory: true)
        try ensureDirectory(work)
        defer { try? FileManager.default.removeItem(at: work) }
        let database = roots.documents.appendingPathComponent("hibiki.db")
        let monitor = try DatabaseChangeMonitor(database)
        let initialFiles = try ownedInventory(roots, limits: limits)
        let initialState = try fingerprints(initialFiles)
        let snapshot = work.appendingPathComponent("snapshot.sqlite")
        try snapshotDatabase(from: roots.documents.appendingPathComponent("hibiki.db"), to: snapshot)
        let schema = try validateDatabase(snapshot)
        let preferenceURL = work.appendingPathComponent("preferences.plist")
        try preferences.write(to: preferenceURL, options: .atomic)
        var sources: [(String, URL)] = [("Documents/hibiki.db", snapshot), ("preferences.plist", preferenceURL)]
        sources += initialFiles
        try validateOwnedReferences(snapshot, available: Set(initialFiles.map(\.0)), roots: roots)
        guard sources.count <= limits.maximumFiles else { throw LibraryBackupError.invalid("文件数量超过上限") }
        try validatePaths(sources.map(\.0))
        let sizes = try sources.map { try regularFileSize($0.1) }
        let total = try boundedTotal(sizes, maximum: limits.maximumBytes)
        try checkSpace(at: roots.state, bytes: total, reserve: limits.freeSpaceReserve)
        let zipURL = work.appendingPathComponent("export.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        var records: [LibraryBackupManifest.File] = [], completed: Int64 = 0
        for ((path, url), expectedSize) in zip(sources, sizes) {
            try checkCancellation()
            let before = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey])
            let handle = try readHandle(url)
            defer { try? handle.close() }
            var hash = SHA256(), count: Int64 = 0
            try archive.addEntry(with: path, type: .file, uncompressedSize: expectedSize,
                                 compressionMethod: .none, bufferSize: chunkSize) { position, requested in
                try checkCancellation()
                guard position == count else { throw LibraryBackupError.invalid("压缩写入位置异常") }
                let data = try handle.read(upToCount: requested) ?? Data()
                count += Int64(data.count)
                guard count <= expectedSize else { throw LibraryBackupError.changedDuringBackup }
                hash.update(data: data); completed += Int64(data.count); progress?(completed, total)
                return data
            }
            let after = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey])
            guard count == expectedSize, before.fileSize == after.fileSize,
                  before.contentModificationDate == after.contentModificationDate, after.isSymbolicLink != true else {
                throw LibraryBackupError.changedDuringBackup
            }
            records.append(.init(path: path, bytes: count, sha256: hex(hash.finalize())))
        }
        guard try fingerprints(ownedInventory(roots, limits: limits)) == initialState,
              try monitor.unchanged() else { throw LibraryBackupError.changedDuringBackup }
        let manifest = LibraryBackupManifest(ownedSources: try ownedSources(snapshot, roots: roots), format: "simo-library-backup", version: 1, createdAt: Date(),
            appVersion: appVersion, databaseSchema: schema, files: records,
            externalSources: try externalSources(snapshot, roots: roots), externalMediaPolicy: externalPolicy)
        let encoded = try JSONEncoder().encode(manifest)
        guard encoded.count <= limits.manifestBytes else { throw LibraryBackupError.invalid("清单过大") }
        try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(encoded.count),
                             compressionMethod: .none, bufferSize: chunkSize) { offset, count in
            encoded.subdata(in: Int(offset)..<min(encoded.count, Int(offset) + count))
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw LibraryBackupError.invalid("导出目标已存在") }
        try ensureDirectory(destination.deletingLastPathComponent())
        try FileManager.default.moveItem(at: zipURL, to: destination)
        return manifest
    }

    /// Extract only to a fresh private directory. Every entry/byte/hash is checked before confirmation.
    static func prepareRestore(archiveURL: URL, roots: LibraryBackupRoots, limits: LibraryBackupLimits = .init(),
                               progress: (@Sendable (Int64, Int64) -> Void)? = nil) throws -> Prepared {
        try checkCancellation(); try ensureDirectory(roots.state)
        let id = UUID()
        let directory = roots.state.appendingPathComponent("prepared-" + id.uuidString, isDirectory: true)
        try ensureDirectory(directory)
        var retain = false
        defer { if !retain { try? FileManager.default.removeItem(at: directory) } }
        // Copy the provider file first; validation and extraction never race an external provider changing it.
        let localArchive = directory.appendingPathComponent("input.zip")
        let archiveBytes = try regularFileSize(archiveURL)
        guard archiveBytes > 0, archiveBytes <= limits.maximumBytes + limits.manifestBytes + 64 * 1024 * 1024 else {
            throw LibraryBackupError.invalid("备份文件大小不受支持")
        }
        try checkSpace(at: roots.state, bytes: archiveBytes, reserve: limits.freeSpaceReserve)
        try FileManager.default.copyItem(at: archiveURL, to: localArchive)
        let archive = try Archive(url: localArchive, accessMode: .read)
        let entries = Array(archive)
        guard entries.count <= limits.maximumFiles + 1, entries.allSatisfy({ $0.type == .file }) else {
            throw LibraryBackupError.invalid("文件数量或类型不受支持；不允许符号链接")
        }
        try validatePaths(entries.map(\.path))
        guard let manifestEntry = entries.first(where: { $0.path == "manifest.json" }),
              manifestEntry.uncompressedSize <= UInt64(limits.manifestBytes) else { throw LibraryBackupError.invalid("缺少有效清单") }
        var manifestData = Data()
        let crc = try archive.extract(manifestEntry, bufferSize: chunkSize, skipCRC32: false) { data in
            guard manifestData.count + data.count <= limits.manifestBytes else { throw LibraryBackupError.invalid("清单过大") }
            manifestData.append(data)
        }
        guard crc == manifestEntry.checksum else { throw LibraryBackupError.invalid("清单校验失败") }
        let manifest = try JSONDecoder().decode(LibraryBackupManifest.self, from: manifestData)
        guard manifest.format == "simo-library-backup", manifest.version == 1,
              (1...currentSchema).contains(manifest.databaseSchema) else { throw LibraryBackupError.unsupportedSchema }
        try validatePaths(manifest.files.map(\.path))
        guard manifest.files.count <= limits.maximumFiles,
              manifest.files.allSatisfy({ permittedPayloadPath($0.path) && $0.bytes >= 0 && isHash($0.sha256) }),
              Set(manifest.files.map(\.path)) == Set(entries.map(\.path)).subtracting(["manifest.json"]),
              manifest.files.contains(where: { $0.path == "Documents/hibiki.db" }),
              manifest.files.contains(where: { $0.path == "preferences.plist" && $0.bytes <= limits.preferencesBytes }) else {
            throw LibraryBackupError.invalid("清单与文件内容不一致")
        }
        let total = try boundedTotal(manifest.files.map(\.bytes), maximum: limits.maximumBytes)
        try checkSpace(at: roots.state, bytes: total, reserve: limits.freeSpaceReserve)
        let payload = directory.appendingPathComponent("payload", isDirectory: true)
        try ensureDirectory(payload)
        var completed: Int64 = 0
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        for file in manifest.files {
            try checkCancellation()
            guard let entry = byPath[file.path], entry.uncompressedSize == UInt64(file.bytes) else {
                throw LibraryBackupError.invalid("文件大小与清单不一致")
            }
            let destination = payload.appendingPathComponent(file.path)
            try ensureDirectory(destination.deletingLastPathComponent())
            let handle = try exclusiveHandle(destination)
            defer { try? handle.close() }
            var hash = SHA256(), size: Int64 = 0
            let crc = try archive.extract(entry, bufferSize: chunkSize, skipCRC32: false) { data in
                try checkCancellation()
                let next = size + Int64(data.count)
                guard next <= file.bytes else { throw LibraryBackupError.invalid("展开数据超过声明大小") }
                try handle.write(contentsOf: data); hash.update(data: data); size = next
                completed += Int64(data.count); progress?(completed, total)
            }
            try handle.close()
            guard size == file.bytes, hex(hash.finalize()) == file.sha256, crc == entry.checksum else {
                throw LibraryBackupError.invalid("文件完整性校验失败")
            }
        }
        guard try validateDatabase(payload.appendingPathComponent("Documents/hibiki.db")) == manifest.databaseSchema else {
            throw LibraryBackupError.invalid("数据库版本与清单不符")
        }
        try validateOwnedSourceManifest(manifest, payload: payload)
        try validateRestoredReferences(manifest, payload: payload)
        _ = try LibraryBackupPreferences.decode(Data(contentsOf: payload.appendingPathComponent("preferences.plist")))
        try ensureDirectory(payload.appendingPathComponent("ApplicationSupport", isDirectory: true))
        try manifestData.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        try FileManager.default.removeItem(at: localArchive)
        retain = true
        return Prepared(id: id, directory: directory, manifest: manifest)
    }

    static func permittedPayloadPath(_ path: String) -> Bool {
        if path == "preferences.plist" || path == "Documents/hibiki.db" { return true }
        if path.hasPrefix("Documents/") {
            return !excludedDocumentComponent(String(path.dropFirst("Documents/".count).split(separator: "/")[0]))
        }
        if path.hasPrefix("ApplicationSupport/") {
            return !excludedSupportComponent(String(path.dropFirst("ApplicationSupport/".count).split(separator: "/")[0]))
        }
        return false
    }
    static func excludedDocumentComponent(_ name: String) -> Bool {
        ["hibiki.db", "hibiki.db-wal", "hibiki.db-shm", "debug.log", ".ImportStaging"].contains(name)
            || name.lowercased().hasSuffix(".simobackup")
    }
    static func excludedSupportComponent(_ name: String) -> Bool {
        // Old upgrade database snapshots and derived caches are not current user assets.
        ["UpgradeBackups", "Caches", "Cache", "MediaCache", "NetworkMediaCache"].contains(name)
    }
    static func ownedInventory(_ roots: LibraryBackupRoots, limits: LibraryBackupLimits) throws -> [(String, URL)] {
        try inventory(roots.documents, prefix: "Documents", limits: limits)
            + inventory(roots.applicationSupport, prefix: "ApplicationSupport", limits: limits)
    }
    static func fingerprints(_ files: [(String, URL)]) throws -> [String: String] {
        var result: [String: String] = [:]
        for (path, url) in files {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw LibraryBackupError.changedDuringBackup }
            result[path] = "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        }
        return result
    }
    final class DatabaseChangeMonitor {
        private let db: OpaquePointer
        private let initial: [[String]]
        init(_ url: URL) throws {
            var pointer: OpaquePointer?
            guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
                if let pointer { sqlite3_close(pointer) }; throw LibraryBackupError.invalid("数据库无法读取")
            }
            db = pointer
            do { initial = try query(pointer, "PRAGMA data_version") }
            catch { sqlite3_close(pointer); throw error }
        }
        deinit { sqlite3_close(db) }
        func unchanged() throws -> Bool { try query(db, "PRAGMA data_version") == initial }
    }
    static func inventory(_ root: URL, prefix: String, limits: LibraryBackupLimits) throws -> [(String, URL)] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try ensureDirectory(root)
        var result: [(String, URL)] = []
        func walk(_ url: URL, _ relative: String) throws {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) {
                try checkCancellation()
                if prefix == "Documents", relative.isEmpty, excludedDocumentComponent(child.lastPathComponent) { continue }
                if prefix == "ApplicationSupport", relative.isEmpty, excludedSupportComponent(child.lastPathComponent) { continue }
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw LibraryBackupError.invalid("资料目录中存在符号链接") }
                let path = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                if values.isDirectory == true { try walk(child, path) }
                else if values.isRegularFile == true { result.append((prefix + "/" + path, child)) }
                else { throw LibraryBackupError.invalid("资料目录包含不支持的文件类型") }
                guard result.count <= limits.maximumFiles else { throw LibraryBackupError.invalid("文件数量超过上限") }
            }
        }
        try walk(root, ""); return result.sorted { $0.0 < $1.0 }
    }
    static func validatePaths(_ paths: [String]) throws {
        var canonical = Set<String>()
        for path in paths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\\"), !path.contains("\0"),
                  !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw LibraryBackupError.invalid("不安全的文件路径") }
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard canonical.insert(key).inserted else { throw LibraryBackupError.invalid("重复或大小写冲突的路径") }
        }
        for path in canonical {
            let parts = path.split(separator: "/")
            if parts.count > 1 {
                for count in 1..<parts.count where canonical.contains(parts.prefix(count).joined(separator: "/")) {
                    throw LibraryBackupError.invalid("文件与目录路径冲突")
                }
            }
        }
    }
    static func checkSpace(at url: URL, bytes: Int64, reserve: Int64) throws {
        guard bytes >= 0, reserve >= 0, bytes <= Int64.max - reserve else { throw LibraryBackupError.insufficientSpace }
        let values = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        guard let available = (values[.systemFreeSize] as? NSNumber)?.int64Value, available >= bytes + reserve else {
            throw LibraryBackupError.insufficientSpace
        }
    }
    static func boundedTotal(_ values: [Int64], maximum: Int64) throws -> Int64 {
        var total: Int64 = 0
        for value in values {
            guard value >= 0, value <= maximum - total else { throw LibraryBackupError.invalid("备份展开大小超过上限") }
            total += value
        }
        return total
    }
    static func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let v = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard v.isDirectory == true, v.isSymbolicLink != true else { throw LibraryBackupError.invalid("目标目录不安全") }
        } else { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
    }
    static func regularFileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw LibraryBackupError.invalid("不是普通文件")
        }
        return Int64(size)
    }
    static func readHandle(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw LibraryBackupError.invalid("无法读取文件") }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    static func exclusiveHandle(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw LibraryBackupError.invalid("无法创建安全暂存文件") }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    static func checkCancellation() throws { if Task.isCancelled { throw CancellationError() } }
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
    static func isHash(_ text: String) -> Bool { text.count == 64 && text.allSatisfy { "0123456789abcdef".contains($0) } }

    static func withDatabase<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw LibraryBackupError.invalid("数据库无法读取")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        return try body(db)
    }
    static func snapshotDatabase(from source: URL, to target: URL) throws {
        _ = try regularFileSize(source)
        try withDatabase(source) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "VACUUM INTO ?", -1, &statement, nil) == SQLITE_OK, let statement else {
                throw LibraryBackupError.invalid("无法建立数据库快照")
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, target.path, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw LibraryBackupError.invalid("数据库快照失败，请稍后再试") }
        }
    }
    static func query(_ db: OpaquePointer, _ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw LibraryBackupError.invalid("数据库结构无效") }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw LibraryBackupError.invalid("数据库检查失败") }
            rows.append((0..<sqlite3_column_count(statement)).map { sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "" })
        }
        return rows
    }
    static func validateDatabase(_ url: URL) throws -> Int {
        try withDatabase(url) { db in
            guard try query(db, "PRAGMA quick_check") == [["ok"]],
                  let version = Int(try query(db, "PRAGMA user_version").first?.first ?? ""),
                  (1...currentSchema).contains(version) else { throw LibraryBackupError.unsupportedSchema }
            let tables = Set(try query(db, "SELECT name FROM sqlite_master WHERE type='table'").compactMap(\.first))
            guard Set(["source", "work", "track"]).isSubset(of: tables) else { throw LibraryBackupError.invalid("不是厮磨媒体库数据库") }
            // A forged user_version must not make an unrelated or incomplete schema acceptable.
            var expected: OpaquePointer?
            guard sqlite3_open(":memory:", &expected) == SQLITE_OK, let expected else { throw LibraryBackupError.invalid("数据库结构检查失败") }
            defer { sqlite3_close(expected) }
            for migration in Schema.migrations where migration.version <= version {
                guard sqlite3_exec(expected, migration.sql, nil, nil, nil) == SQLITE_OK else { throw LibraryBackupError.invalid("数据库结构检查失败") }
            }
            let expectedTables = try query(expected, "SELECT name FROM sqlite_master WHERE type='table'").compactMap(\.first)
            for table in expectedTables {
                guard tables.contains(table), try query(db, "PRAGMA table_info(\(table))") == query(expected, "PRAGMA table_info(\(table))") else {
                    throw LibraryBackupError.invalid("数据库结构与版本不一致")
                }
            }
            return version
        }
    }
    static func ownedPayloadPath(_ path: String, roots: LibraryBackupRoots) -> String? {
        for (prefix, root) in [("Documents", roots.documents), ("ApplicationSupport", roots.applicationSupport)] {
            let base = root.standardizedFileURL.path
            if path == base { return prefix }
            if path.hasPrefix(base + "/") { return prefix + String(path.dropFirst(base.count)) }
        }
        // iOS can move a sandbox between installs. Only recognize its UUID container shape,
        // and only if the corresponding owned file/directory exists in this sandbox.
        let pattern = #"/Containers/Data/Application/[0-9A-Fa-f-]{36}/(Documents|Library/Application Support)(/.*)?$"#
        if let range = path.range(of: pattern, options: .regularExpression) {
            let suffix = String(path[range])
            for (marker, prefix, root) in [("/Documents", "Documents", roots.documents),
                                           ("/Library/Application Support", "ApplicationSupport", roots.applicationSupport)] {
                if let markerRange = suffix.range(of: marker) {
                    let tail = String(suffix[markerRange.upperBound...])
                    let target = root.path + tail
                    if (try? validatePaths([prefix + tail])) != nil, FileManager.default.fileExists(atPath: target) { return prefix + tail }
                }
            }
        }
        return nil
    }
    static func ownedSources(_ database: URL, roots: LibraryBackupRoots) throws -> [LibraryBackupManifest.OwnedSource] {
        try withDatabase(database) { db in
            try query(db, "SELECT id,COALESCE(root_path,'') FROM source").compactMap { row in
                guard let id = Int64(row[0]), let payload = ownedPayloadPath(row[1], roots: roots) else { return nil }
                return .init(id: id, originalRoot: row[1], payloadRoot: payload)
            }
        }
    }
    static func validateOwnedSourceManifest(_ manifest: LibraryBackupManifest, payload: URL) throws {
        guard Set(manifest.ownedSources.map(\.id)).count == manifest.ownedSources.count else { throw LibraryBackupError.invalid("本地来源与清单不一致") }
        try withDatabase(payload.appendingPathComponent("Documents/hibiki.db")) { db in
            let rows = try query(db, "SELECT id,COALESCE(root_path,'') FROM source")
            for source in manifest.ownedSources {
                try validatePaths([source.payloadRoot])
                guard source.payloadRoot == "Documents" || source.payloadRoot == "ApplicationSupport" || permittedPayloadPath(source.payloadRoot),
                      rows.contains(where: { $0[0] == String(source.id) && $0[1] == source.originalRoot }),
                      source.originalRoot.hasPrefix("/") else { throw LibraryBackupError.invalid("本地来源与清单不一致") }
                // Empty owned source directories also need a valid destination after migration.
                try ensureDirectory(payload.appendingPathComponent(source.payloadRoot))
            }
        }
    }
    static func validateRestoredReferences(_ manifest: LibraryBackupManifest, payload: URL) throws {
        let roots = LibraryBackupRoots(documents: payload.appendingPathComponent("Documents"),
            applicationSupport: payload.appendingPathComponent("ApplicationSupport"), state: payload.deletingLastPathComponent())
        try validateOwnedReferences(roots.documents.appendingPathComponent("hibiki.db"),
            available: Set(manifest.files.map(\.path)), roots: roots, sourceOverrides: manifest.ownedSources)
    }
    static func validateOwnedReferences(_ database: URL, available: Set<String>, roots: LibraryBackupRoots,
                                       sourceOverrides: [LibraryBackupManifest.OwnedSource] = []) throws {
        try withDatabase(database) { db in
            let tables = Set(try query(db, "SELECT name FROM sqlite_master WHERE type='table'").compactMap(\.first))
            func values(_ table: String, _ column: String) throws -> [String] {
                guard tables.contains(table), try query(db, "PRAGMA table_info(\(table))").contains(where: { $0[1] == column }) else { return [] }
                return try query(db, "SELECT \(column) FROM \(table) WHERE \(column) IS NOT NULL AND \(column) <> ''").compactMap(\.first)
            }
            func hasColumn(_ table: String, _ column: String) throws -> Bool {
                guard tables.contains(table) else { return false }
                return try query(db, "PRAGMA table_info(\(table))").contains(where: { $0[1] == column })
            }
            var required: [String] = []
            for (table, column) in [("track", "asset_relative_path"), ("work", "cover_asset_path"),
                                    ("work_attachment", "asset_relative_path"), ("creator", "avatar_asset_path"), ("creator", "cover_asset_path")] {
                required += try values(table, column).map { "ApplicationSupport/WorkAssets/" + $0 }
            }
            required += try values("playlist_entry", "clip_filename").map { "ApplicationSupport/PlaylistClips/" + $0 }
            required += try values("track", "file_path").compactMap { ownedPayloadPath($0, roots: roots) }
            let groupingColumn = try hasColumn("source", "grouping") ? "grouping" : "'automatic'"
            let sourceRows = try query(db, "SELECT id,COALESCE(root_path,''),\(groupingColumn) FROM source")
            let originalRoots = Dictionary(uniqueKeysWithValues: sourceRows.map { ($0[0], $0[1]) })
            let overrides = Dictionary(uniqueKeysWithValues: sourceOverrides.map { (String($0.id), $0.payloadRoot) })
            let owned = Dictionary(uniqueKeysWithValues: sourceRows.compactMap { row -> (String, (String, ScanOptions.Grouping))? in
                guard let path = overrides[row[0]] ?? ownedPayloadPath(row[1], roots: roots) else { return nil }
                return (row[0], (path, ScanOptions.Grouping(rawValue: row[2]) ?? .automatic))
            })
            let coverAssetColumn = try hasColumn("work", "cover_asset_path") ? "COALESCE(cover_asset_path,'')" : "''"
            let folderColumn = try hasColumn("work", "folder_rel") ? "COALESCE(NULLIF(folder_rel,''),folder_path)" : "folder_path"
            let works = try query(db, "SELECT id,source_id,\(folderColumn),COALESCE(cover_path,''),COALESCE(script_path,''),\(coverAssetColumn) FROM work")
            let workCounts = Dictionary(grouping: works, by: { $0[1] }).mapValues(\.count)
            let trackAssetColumn = try hasColumn("track", "asset_relative_path") ? "COALESCE(asset_relative_path,'')" : "''"
            let tracks = Dictionary(grouping: try query(db, "SELECT work_id,COALESCE(relative_path,''),file_name,\(trackAssetColumn) FROM track"), by: { $0[0] })
            let attachments = tables.contains("work_attachment")
                ? Dictionary(grouping: try query(db, "SELECT work_id,relative_path,COALESCE(asset_relative_path,'') FROM work_attachment"), by: { $0[0] }) : [:]
            for work in works {
                guard let (sourceRoot, grouping) = owned[work[1]] else { continue }
                var folder = work[2]
                if folder.hasPrefix("/") {
                    let original = originalRoots[work[1]] ?? ""
                    if folder == original { folder = "" }
                    else if !original.isEmpty, folder.hasPrefix(original + "/") { folder = String(folder.dropFirst(original.count + 1)) }
                    else if let anchored = ownedPayloadPath(folder, roots: roots), anchored.hasPrefix(sourceRoot + "/") {
                        folder = String(anchored.dropFirst(sourceRoot.count + 1))
                    } else { throw LibraryBackupError.invalid("不安全的文件路径") }
                }
                let directory = LibraryPathResolver.workDirectory(root: sourceRoot, workRelativePath: folder, grouping: grouping)
                if !work[3].isEmpty, work[5].isEmpty { required.append(LibraryPathResolver.join(root: directory, relative: work[3])) }
                if !work[4].isEmpty { required.append(LibraryPathResolver.join(root: directory, relative: work[4])) }
                // Infer from source + work + relative filename, even when the old absolute path no longer exists.
                for track in tracks[work[0]] ?? [] where track[3].isEmpty {
                    required.append(LibraryPathResolver.join(root: directory, relative: track[1].isEmpty ? track[2] : track[1]))
                }
                let attachmentRoot = grouping == .automatic && workCounts[work[1]] == 1
                    && WorkAttachmentFinder.isLegacyFormatFolder(folder) ? sourceRoot : directory
                for attachment in attachments[work[0]] ?? [] where attachment[2].isEmpty {
                    required.append(LibraryPathResolver.join(root: attachmentRoot, relative: attachment[1]))
                }
            }
            func imageReferences(_ object: Any) {
                if let dictionary = object as? [String: Any] {
                    for (key, value) in dictionary {
                        if ["avatarAssetPath", "backgroundAssetPath", "coverAssetPath"].contains(key), let path = value as? String, !path.isEmpty {
                            required.append("ApplicationSupport/WorkAssets/" + path)
                        } else { imageReferences(value) }
                    }
                } else if let array = object as? [Any] { array.forEach(imageReferences) }
            }
            for json in try values("call_profile", "profile_json") { imageReferences(try JSONSerialization.jsonObject(with: Data(json.utf8))) }
            try validatePaths(Array(Set(required)))
            guard Set(required).isSubset(of: available) else { throw LibraryBackupError.invalid("部分 App 内媒体或图片已缺失，请修复后重新备份") }
        }
    }
    /// The staged DB is closed; reanchor only explicit App-owned source roots recorded by export.
    static func reanchorOwnedSources(_ database: URL, manifest: LibraryBackupManifest, roots: LibraryBackupRoots) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw LibraryBackupError.invalid("恢复数据库无法打开")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw LibraryBackupError.invalid("无法重建本地来源路径") }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        for source in manifest.ownedSources {
            try validatePaths([source.payloadRoot])
            let root: URL
            if source.payloadRoot == "Documents" { root = roots.documents }
            else if source.payloadRoot.hasPrefix("Documents/") { root = roots.documents.appendingPathComponent(String(source.payloadRoot.dropFirst(10))) }
            else if source.payloadRoot == "ApplicationSupport" { root = roots.applicationSupport }
            else if source.payloadRoot.hasPrefix("ApplicationSupport/") { root = roots.applicationSupport.appendingPathComponent(String(source.payloadRoot.dropFirst(19))) }
            else { throw LibraryBackupError.invalid("本地来源位置无效") }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE source SET root_path=?,bookmark=NULL WHERE id=? AND root_path=?", -1, &statement, nil) == SQLITE_OK, let statement else { throw LibraryBackupError.invalid("本地来源结构无效") }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, root.path, -1, transient); sqlite3_bind_int64(statement, 2, source.id)
            sqlite3_bind_text(statement, 3, source.originalRoot, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw LibraryBackupError.invalid("本地来源与清单不一致") }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw LibraryBackupError.invalid("本地来源路径保存失败") }
        committed = true
    }
    static func externalSources(_ database: URL, roots: LibraryBackupRoots) throws -> [LibraryBackupManifest.ExternalSource] {
        try withDatabase(database) { db in
            try query(db, "SELECT name,type,COALESCE(root_path,'') FROM source").compactMap { row in
                guard row.count == 3 else { return nil }
                guard !(row[1] == "local" && row[2].isEmpty) else { return nil }
                guard ownedPayloadPath(row[2], roots: roots) == nil else { return nil }
                // Absolute paths are never a portable access grant; even internal sources may need reanchoring.
                return .init(name: row[0], kind: row[1], mediaIncluded: false, availability: "notChecked")
            }
        }
    }
}

private func backupText(_ value: String) -> String {
    #if os(iOS)
    return InterfaceLocalization.key(value)
    #else
    return value
    #endif
}
