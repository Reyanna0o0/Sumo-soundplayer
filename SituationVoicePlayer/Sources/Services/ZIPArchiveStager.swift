import Foundation
import CryptoKit
import Darwin
import ZIPFoundation

struct ZIPStagingProgress: Sendable {
    enum Phase: Sendable { case copying, inspecting, extracting, ready }
    let phase: Phase
    let completedBytes: Int64
    let totalBytes: Int64
    let completedEntries: Int
    let totalEntries: Int
}

/// Owns only the new UUID directory. Database writes belong to the caller.
/// Call promote(), synchronously commit the database, then retain().
final class PreparedZIPImport: @unchecked Sendable {
    let id: UUID
    let archiveSHA256: String
    let originalFileName: String
    let manifest: ZIPArchiveManifest
    let stagingURL: URL
    let finalURL: URL
    private let jobURL: URL
    private let token: Data
    private let lock = NSLock()
    private enum State { case staged, promoted, retained, disposed }
    private var state: State = .staged

    fileprivate init(id: UUID, hash: String, originalName: String, manifest: ZIPArchiveManifest,
                     jobURL: URL, finalURL: URL, token: Data) {
        self.id = id; archiveSHA256 = hash; originalFileName = originalName; self.manifest = manifest
        self.jobURL = jobURL; stagingURL = jobURL.appendingPathComponent("contents", isDirectory: true)
        self.finalURL = finalURL; self.token = token
    }

    @discardableResult
    func promote() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard state == .staged else { throw ZIPImportError.invalidLifecycle }
        try ZIPArchiveStager.verifyOwner(at: jobURL, token: token)
        try ZIPArchiveStager.verifyOwner(at: stagingURL, token: token)
        try ZIPArchiveStager.ensureDirectory(finalURL.deletingLastPathComponent())
        guard !FileManager.default.fileExists(atPath: finalURL.path) else { throw ZIPImportError.duplicatePath(finalURL.lastPathComponent) }
        try FileManager.default.moveItem(at: stagingURL, to: finalURL)
        state = .promoted
        // Remove the copied ZIP before returning; retain() must be infallible.
        try FileManager.default.removeItem(at: jobURL)
        return finalURL
    }

    /// Deliberately pure memory and nonthrowing: never delete files after database commit.
    func retain() {
        lock.lock(); defer { lock.unlock() }
        state = .retained
    }

    func dispose() throws {
        lock.lock(); defer { lock.unlock() }
        guard state != .retained, state != .disposed else { return }
        if state == .promoted, FileManager.default.fileExists(atPath: finalURL.path) {
            try ZIPArchiveStager.verifyOwner(at: finalURL, token: token)
            try FileManager.default.removeItem(at: finalURL)
        }
        if FileManager.default.fileExists(atPath: jobURL.path) {
            try ZIPArchiveStager.verifyOwner(at: jobURL, token: token)
            try FileManager.default.removeItem(at: jobURL)
        }
        state = .disposed
    }
    deinit { try? dispose() }
}

enum ZIPArchiveStager {
    private static let ownerName = ".sumo-zip-import-owner"
    private static let chunkSize = 256 * 1_024

    static func prepare(from sourceURL: URL, documentsURL: URL? = nil, limits: ZIPImportLimits = .default,
                        progress: (@Sendable (ZIPStagingProgress) -> Void)? = nil) async throws -> PreparedZIPImport {
        let cancellation = ZIPStagingCancellation()
        let operation = Task.detached(priority: .userInitiated) {
            try prepareSynchronously(from: sourceURL, documentsURL: documentsURL, limits: limits,
                                     cancellation: cancellation, progress: progress)
        }
        return try await withTaskCancellationHandler {
            let prepared = try await operation.value
            do { try Task.checkCancellation(); return prepared }
            catch { try? prepared.dispose(); throw error }
        } onCancel: {
            cancellation.cancel(); operation.cancel()
        }
    }

    private static func prepareSynchronously(from source: URL, documentsURL: URL?, limits: ZIPImportLimits,
        cancellation: ZIPStagingCancellation, progress: (@Sendable (ZIPStagingProgress) -> Void)?) throws -> PreparedZIPImport {
        try cancellation.check()
        guard source.pathExtension.lowercased() == "zip" else { throw ZIPImportError.unsupportedArchive(InterfaceLocalization.text("请选择单个 .zip 文件")) }
        let fm = FileManager.default
        let documents = try documentsURL ?? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try ensureDirectory(documents)
        let stagingParent = documents.appendingPathComponent(".ImportStaging", isDirectory: true)
        let finalParent = documents.appendingPathComponent("ImportedArchives", isDirectory: true)
        try ensureDirectory(stagingParent); try ensureDirectory(finalParent)
        let id = UUID(), token = Data("SumoZIPImport:\(UUID().uuidString)".utf8)
        let job = stagingParent.appendingPathComponent(id.uuidString, isDirectory: true)
        let contents = job.appendingPathComponent("contents", isDirectory: true)
        try createDirectoryExclusively(job)
        var handedOff = false
        defer {
            if !handedOff, (try? verifyOwner(at: job, token: token)) != nil {
                // Never remove a replacement directory whose ownership token no longer matches.
                try? fm.removeItem(at: job)
            }
        }
        try writeExclusively(token, to: job.appendingPathComponent(ownerName))
        try createDirectoryExclusively(contents)
        try writeExclusively(token, to: contents.appendingPathComponent(ownerName))
        let archiveURL = job.appendingPathComponent("input.zip")
        let digest = try copySelectedZIP(source, to: archiveURL, limits: limits, cancellation: cancellation, progress: progress)
        progress?(.init(phase: .inspecting, completedBytes: 0, totalBytes: 0, completedEntries: 0, totalEntries: 0))
        let manifest = try ZIPArchiveInspector.inspect(at: archiveURL, limits: limits, checkCancellation: cancellation.check)
        try checkSpace(at: job, requiredBytes: manifest.totalUncompressedBytes, reserve: limits.freeSpaceReserveBytes)
        let archive = try Archive(url: archiveURL, accessMode: .read)
        let iterator = archive.makeIterator()
        var completed: UInt64 = 0, entriesDone = 0, spaceCheckBytes: UInt64 = 0
        for expected in manifest.entries {
            try cancellation.check()
            guard let entry = iterator.next(), entry.path == expected.archivePath,
                  entry.uncompressedSize == expected.uncompressedBytes, entry.compressedSize == expected.compressedBytes,
                  entry.checksum == expected.crc32,
                  entry.type == (expected.isDirectory ? .directory : .file) else {
                throw ZIPImportError.integrityFailure(expected.relativePath)
            }
            guard expected.relativePath.split(separator: "/").first != Substring(ownerName) else {
                throw ZIPImportError.unsafePath(expected.relativePath)
            }
            let output = contents.appendingPathComponent(expected.relativePath, isDirectory: expected.isDirectory)
            try ensureParents(of: output, root: contents)
            if expected.isDirectory {
                try ensureDirectory(output)
            } else {
                let handle = try exclusiveHandle(output)
                defer { try? handle.close() }
                var entryBytes: UInt64 = 0
                let extractionProgress = Progress(totalUnitCount: Int64(expected.uncompressedBytes))
                cancellation.setProgress(extractionProgress)
                defer { cancellation.setProgress(nil) }
                let actualCRC = try archive.extract(entry, bufferSize: chunkSize, skipCRC32: false,
                                                    progress: extractionProgress) { data in
                    try cancellation.check()
                    let bytes = UInt64(data.count)
                    guard entryBytes <= expected.uncompressedBytes, bytes <= expected.uncompressedBytes - entryBytes,
                          completed <= limits.maximumUncompressedBytes, bytes <= limits.maximumUncompressedBytes - completed else {
                        throw ZIPImportError.resourceLimit(InterfaceLocalization.text("实际展开的数据超过声明值或总量上限"))
                    }
                    try handle.write(contentsOf: data)
                    entryBytes += bytes; completed += bytes; spaceCheckBytes += bytes
                    if spaceCheckBytes >= 64 * 1_024 * 1_024 {
                        try checkSpace(at: job, requiredBytes: manifest.totalUncompressedBytes - completed,
                                       reserve: limits.freeSpaceReserveBytes)
                        spaceCheckBytes = 0
                    }
                    progress?(.init(phase: .extracting, completedBytes: Int64(completed),
                        totalBytes: Int64(manifest.totalUncompressedBytes), completedEntries: entriesDone,
                        totalEntries: manifest.entries.count))
                }
                guard entryBytes == expected.uncompressedBytes, actualCRC == expected.crc32 else {
                    throw ZIPImportError.integrityFailure(expected.relativePath)
                }
                try handle.close()
            }
            entriesDone += 1
        }
        guard iterator.next() == nil, completed == manifest.totalUncompressedBytes,
              entriesDone == manifest.entries.count else { throw ZIPImportError.integrityFailure(InterfaceLocalization.text("文件数量或展开总量不一致")) }
        try cancellation.check()
        let prepared = PreparedZIPImport(id: id, hash: digest, originalName: source.lastPathComponent, manifest: manifest,
            jobURL: job, finalURL: finalParent.appendingPathComponent(id.uuidString, isDirectory: true), token: token)
        handedOff = true
        progress?(.init(phase: .ready, completedBytes: Int64(completed), totalBytes: Int64(completed),
                        completedEntries: entriesDone, totalEntries: entriesDone))
        return prepared
    }

    private static func copySelectedZIP(_ source: URL, to destination: URL, limits: ZIPImportLimits,
        cancellation: ZIPStagingCancellation, progress: (@Sendable (ZIPStagingProgress) -> Void)?) throws -> String {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?, result: Result<String, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
            result = Result {
                try cancellation.check()
                let values = try coordinated.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size >= 0 else {
                    throw ZIPImportError.invalidArchive(InterfaceLocalization.text("选择的 ZIP 无法作为普通文件读取"))
                }
                guard UInt64(size) <= limits.maximumArchiveBytes, UInt64(size) <= UInt64(Int64.max) else {
                    throw ZIPImportError.resourceLimit(InterfaceLocalization.text("压缩包体积过大"))
                }
                try checkSpace(at: destination.deletingLastPathComponent(), requiredBytes: UInt64(size), reserve: limits.freeSpaceReserveBytes)
                let input = try FileHandle(forReadingFrom: coordinated), output = try exclusiveHandle(destination)
                defer { try? input.close(); try? output.close() }
                var hash = SHA256(), copied: UInt64 = 0
                while true {
                    try cancellation.check()
                    let data = try input.read(upToCount: chunkSize) ?? Data()
                    if data.isEmpty { break }
                    guard copied <= UInt64(size), UInt64(data.count) <= UInt64(size) - copied else {
                        throw ZIPImportError.invalidArchive(InterfaceLocalization.text("复制期间压缩包发生变化"))
                    }
                    try output.write(contentsOf: data); hash.update(data: data); copied += UInt64(data.count)
                    progress?(.init(phase: .copying, completedBytes: Int64(copied), totalBytes: Int64(size),
                                    completedEntries: 0, totalEntries: 0))
                }
                guard copied == UInt64(size) else { throw ZIPImportError.invalidArchive(InterfaceLocalization.text("复制的压缩包不完整")) }
                try output.close()
                return hash.finalize().map { String(format: "%02x", $0) }.joined()
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ZIPImportError.invalidArchive(InterfaceLocalization.text("文件提供程序未返回 ZIP")) }
        return try result.get()
    }

    fileprivate static func verifyOwner(at directory: URL, token: Data) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              try Data(contentsOf: directory.appendingPathComponent(ownerName)) == token else { throw ZIPImportError.invalidLifecycle }
    }

    fileprivate static func ensureDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ZIPImportError.unsafePath(url.lastPathComponent) }
        } else { try createDirectoryExclusively(url) }
    }
    private static func createDirectoryExclusively(_ url: URL) throws {
        guard mkdir(url.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private static func exclusiveHandle(_ url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    private static func writeExclusively(_ data: Data, to url: URL) throws {
        let output = try exclusiveHandle(url)
        defer { try? output.close() }
        try output.write(contentsOf: data)
    }
    private static func ensureParents(of url: URL, root: URL) throws {
        let relative = url.deletingLastPathComponent().path.dropFirst(root.path.count)
        var current = root
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            try ensureDirectory(current)
        }
    }
    private static func checkSpace(at url: URL, requiredBytes: UInt64, reserve: UInt64) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        guard available >= 0, UInt64(available) >= reserve, requiredBytes <= UInt64(available) - reserve else {
            throw ZIPImportError.insufficientSpace
        }
    }
}

private final class ZIPStagingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var progress: Progress?
    func cancel() { lock.lock(); cancelled = true; progress?.cancel(); lock.unlock() }
    func check() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped || Task.isCancelled { throw CancellationError() }
    }
    func setProgress(_ progress: Progress?) {
        lock.lock(); self.progress = progress; let stopped = cancelled; lock.unlock()
        if stopped { progress?.cancel() }
    }
}
