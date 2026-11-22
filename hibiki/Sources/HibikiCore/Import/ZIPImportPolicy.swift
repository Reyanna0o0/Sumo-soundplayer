import Foundation

/// Limits apply to the declared sizes AND to the bytes actually produced.
public struct ZIPImportLimits: Sendable {
    public var maximumEntries: Int
    public var maximumArchiveBytes: UInt64
    public var maximumUncompressedBytes: UInt64
    public var maximumEntryBytes: UInt64
    public var maximumDepth: Int
    public var maximumPathBytes: Int
    public var maximumCentralDirectoryBytes: UInt64
    public var freeSpaceReserveBytes: UInt64

    public init(maximumEntries: Int = 10_000, maximumArchiveBytes: UInt64 = 20 * 1_024 * 1_024 * 1_024,
                maximumUncompressedBytes: UInt64 = 20 * 1_024 * 1_024 * 1_024,
                maximumEntryBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024,
                maximumDepth: Int = 32, maximumPathBytes: Int = 1_024,
                maximumCentralDirectoryBytes: UInt64 = 64 * 1_024 * 1_024,
                freeSpaceReserveBytes: UInt64 = 512 * 1_024 * 1_024) {
        self.maximumEntries = maximumEntries; self.maximumArchiveBytes = maximumArchiveBytes
        self.maximumUncompressedBytes = maximumUncompressedBytes; self.maximumEntryBytes = maximumEntryBytes
        self.maximumDepth = maximumDepth; self.maximumPathBytes = maximumPathBytes
        self.maximumCentralDirectoryBytes = maximumCentralDirectoryBytes
        self.freeSpaceReserveBytes = freeSpaceReserveBytes
    }
    public static let `default` = ZIPImportLimits()
}

public enum ZIPImportError: Error, LocalizedError, Equatable {
    case invalidArchive(String), unsupportedArchive(String), unsafePath(String), duplicatePath(String)
    case resourceLimit(String), insufficientSpace, integrityFailure(String), invalidLifecycle

    public var errorDescription: String? {
        switch self {
        case .invalidArchive(let reason): return InterfaceLocalization.text("ZIP 文件不完整或格式有误：\(reason)")
        case .unsupportedArchive(let reason): return InterfaceLocalization.text("暂不支持这个 ZIP：\(reason)")
        case .unsafePath(let path): return InterfaceLocalization.text("ZIP 包含不安全的文件路径：\(path)")
        case .duplicatePath(let path): return InterfaceLocalization.text("ZIP 内有重复或冲突的目标路径：\(path)")
        case .resourceLimit(let reason): return InterfaceLocalization.text("ZIP 超过本次导入的资源上限：\(reason)")
        case .insufficientSpace: return InterfaceLocalization.text("可用空间不足，无法完整解压 ZIP 并保留必要的空余空间。")
        case .integrityFailure(let path): return InterfaceLocalization.text("ZIP 文件校验失败：\(path)。没有登记这次导入。")
        case .invalidLifecycle: return InterfaceLocalization.text("这次 ZIP 导入已结束或状态无效，请重新选择文件。")
        }
    }
}

public struct ZIPArchiveEntry: Sendable, Equatable {
    /// ZIPFoundation's standard UTF-8/CP437 decoding, used to verify iterator identity.
    public let archivePath: String
    /// Validated decoded path; directories have no trailing slash.
    public let relativePath: String
    public let isDirectory: Bool
    public let compressedBytes: UInt64
    public let uncompressedBytes: UInt64
    public let crc32: UInt32
    public let compressionMethod: UInt16
    public let localHeaderOffset: UInt64
}

public struct ZIPArchiveManifest: Sendable, Equatable {
    public let entries: [ZIPArchiveEntry]
    public let archiveBytes: UInt64
    public let totalUncompressedBytes: UInt64
    public let usesZIP64: Bool
}

public enum ZIPImportPathPolicy {
    public static func validated(_ path: String, isDirectory: Bool, limits: ZIPImportLimits = .default) throws -> String {
        let relative = isDirectory && path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"), !relative.contains(":"),
              !relative.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ZIPImportError.unsafePath(path)
        }
        guard parts.count <= limits.maximumDepth, relative.utf8.count <= limits.maximumPathBytes,
              parts.allSatisfy({ $0.utf8.count <= 255 }) else {
            throw ZIPImportError.resourceLimit(InterfaceLocalization.text("文件路径太长或目录层级太深"))
        }
        return relative
    }

    /// Conservatively reject names that collide on case-insensitive or normalization-insensitive volumes.
    public static func collisionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func validateTargets(_ entries: [ZIPArchiveEntry]) throws {
        var explicit: Set<String> = [], files: Set<String> = [], directories: Set<String> = []
        var spellings: [String: String] = [:]
        for entry in entries {
            let key = collisionKey(entry.relativePath)
            let originalParts = entry.relativePath.split(separator: "/")
            for count in 1...originalParts.count {
                let spelling = originalParts.prefix(count).joined(separator: "/"), normalized = collisionKey(spelling)
                if let previous = spellings[normalized], Array(previous.utf8) != Array(spelling.utf8) {
                    throw ZIPImportError.duplicatePath(entry.relativePath)
                }
                spellings[normalized] = spelling
            }
            guard explicit.insert(key).inserted else { throw ZIPImportError.duplicatePath(entry.relativePath) }
            if entry.isDirectory {
                guard !files.contains(key) else { throw ZIPImportError.duplicatePath(entry.relativePath) }
                directories.insert(key)
            } else {
                guard !directories.contains(key) else { throw ZIPImportError.duplicatePath(entry.relativePath) }
                files.insert(key)
            }
            let parts = key.split(separator: "/")
            if parts.count > 1 {
                for count in 1..<parts.count {
                    let parent = parts.prefix(count).joined(separator: "/")
                    guard !files.contains(parent) else { throw ZIPImportError.duplicatePath(entry.relativePath) }
                    directories.insert(parent)
                }
            }
        }
    }
}

/// Used only for ZIP metadata and fixtures. Extraction uses ZIPFoundation's streaming CRC.
public enum ZIPImportCRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc & 1) == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
        return crc
    }
    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }
}
