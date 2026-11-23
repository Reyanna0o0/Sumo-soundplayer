import Foundation
import CoreFoundation

/// A bounded, read-only structural check. It deliberately runs before ZIPFoundation's
/// non-throwing iterator, which otherwise stops at encrypted or malformed entries.
public enum ZIPArchiveInspector {
    public static func inspect(at url: URL, limits: ZIPImportLimits = .default,
                               checkCancellation: () throws -> Void = {}) throws -> ZIPArchiveManifest {
        try checkCancellation()
        let reader = try ZIPReader(url: url)
        guard reader.size <= limits.maximumArchiveBytes, reader.size <= UInt64(Int64.max) else {
            throw ZIPImportError.resourceLimit(InterfaceLocalization.text("压缩包体积过大"))
        }
        guard reader.size >= 22 else { throw invalid(InterfaceLocalization.text("缺少目录结束记录")) }
        let tailSize = min(reader.size, 65_535 + 22)
        let tail = try reader.read(reader.size - tailSize, Int(tailSize))
        var endIndex: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            if try tail.u32(index) == 0x06054b50,
               index + 22 + Int(try tail.u16(index + 20)) == tail.count { endIndex = index; break }
        }
        guard let endIndex else { throw invalid(InterfaceLocalization.text("缺少完整的目录结束记录")) }
        let endOffset = reader.size - tailSize + UInt64(endIndex)
        let eocd = tail.subdata(in: endIndex..<tail.count)
        var count = UInt64(try eocd.u16(10)), cdSize = UInt64(try eocd.u32(12))
        var cdOffset = UInt64(try eocd.u32(16)), footerOffset = endOffset
        let disk = try eocd.u16(4), cdDisk = try eocd.u16(6), diskCount = try eocd.u16(8)
        let sentinel = count == 0xffff || cdSize == 0xffffffff || cdOffset == 0xffffffff
            || disk == 0xffff || cdDisk == 0xffff || diskCount == 0xffff
        let locator = endOffset >= 20 ? try reader.read(endOffset - 20, 20) : Data()
        let hasZIP64 = try locator.count == 20 && locator.u32(0) == 0x07064b50
        if sentinel && !hasZIP64 { throw invalid(InterfaceLocalization.text("ZIP64 目录缺失")) }
        if hasZIP64 {
            guard try locator.u32(4) == 0, try locator.u32(16) == 1 else { throw splitArchive() }
            footerOffset = try locator.u64(8)
            let record = try reader.read(footerOffset, 56)
            guard try record.u32(0) == 0x06064b50 else { throw invalid(InterfaceLocalization.text("ZIP64 目录签名错误")) }
            let recordSize = try record.u64(4)
            guard recordSize >= 44, recordSize <= 1_048_576,
                  try add(footerOffset, add(12, recordSize)) == endOffset - 20 else { throw invalid(InterfaceLocalization.text("ZIP64 目录范围错误")) }
            guard try record.u32(16) == 0, try record.u32(20) == 0,
                  try record.u64(24) == record.u64(32) else { throw splitArchive() }
            count = try record.u64(32); cdSize = try record.u64(40); cdOffset = try record.u64(48)
            guard (disk == 0 || disk == 0xffff), (cdDisk == 0 || cdDisk == 0xffff),
                  (diskCount == 0xffff || UInt64(diskCount) == count),
                  (try eocd.u16(10) == 0xffff || UInt64(eocd.u16(10)) == count),
                  (try eocd.u32(12) == 0xffffffff || UInt64(eocd.u32(12)) == cdSize),
                  (try eocd.u32(16) == 0xffffffff || UInt64(eocd.u32(16)) == cdOffset) else {
                throw invalid(InterfaceLocalization.text("普通目录与 ZIP64 目录不一致"))
            }
        } else if disk != 0 || cdDisk != 0 || UInt64(diskCount) != count { throw splitArchive() }
        guard count > 0 else { throw invalid(InterfaceLocalization.text("压缩包没有文件")) }
        guard limits.maximumEntries > 0, count <= UInt64(limits.maximumEntries),
              cdSize <= limits.maximumCentralDirectoryBytes, cdSize <= UInt64(Int.max) else {
            throw ZIPImportError.resourceLimit(InterfaceLocalization.text("文件数量或目录索引过大"))
        }
        guard try add(cdOffset, cdSize) == footerOffset else { throw invalid(InterfaceLocalization.text("中央目录范围不一致")) }
        let central = try reader.read(cdOffset, Int(cdSize))
        var cursor = 0, entries: [ZIPArchiveEntry] = [], spans: [(UInt64, UInt64)] = []
        var total: UInt64 = 0
        for _ in 0..<Int(count) {
            try checkCancellation()
            guard try central.u32(cursor) == 0x02014b50 else { throw invalid(InterfaceLocalization.text("中央目录条目缺失")) }
            let version = try central.u16(cursor + 6), flags = try central.u16(cursor + 8)
            let method = try central.u16(cursor + 10), crc = try central.u32(cursor + 16)
            try validateFlags(flags, method: method, version: version)
            let nameCount = Int(try central.u16(cursor + 28)), extraCount = Int(try central.u16(cursor + 30))
            let commentCount = Int(try central.u16(cursor + 32))
            let next = cursor + 46 + nameCount + extraCount + commentCount
            guard next <= central.count else { throw invalid(InterfaceLocalization.text("中央目录条目被截断")) }
            let rawName = central.subdata(in: (cursor + 46)..<(cursor + 46 + nameCount))
            let extra = try extras(central.subdata(in: (cursor + 46 + nameCount)..<(cursor + 46 + nameCount + extraCount)))
            let compressed32 = try central.u32(cursor + 20), uncompressed32 = try central.u32(cursor + 24)
            let offset32 = try central.u32(cursor + 42), disk16 = try central.u16(cursor + 34)
            var zip64Cursor = 0
            let zip64 = extra[1] ?? Data()
            func extended(_ normal: UInt64, _ marker: UInt64, width: Int = 8) throws -> UInt64 {
                guard normal == marker else { return normal }
                defer { zip64Cursor += width }
                return width == 8 ? try zip64.u64(zip64Cursor) : UInt64(try zip64.u32(zip64Cursor))
            }
            let uncompressed = try extended(UInt64(uncompressed32), 0xffffffff)
            let compressed = try extended(UInt64(compressed32), 0xffffffff)
            let offset = try extended(UInt64(offset32), 0xffffffff)
            guard try extended(UInt64(disk16), 0xffff, width: 4) == 0 else { throw splitArchive() }
            guard uncompressed <= limits.maximumEntryBytes else { throw ZIPImportError.resourceLimit(InterfaceLocalization.text("单个文件展开后过大")) }
            total = try add(total, uncompressed)
            guard total <= limits.maximumUncompressedBytes else { throw ZIPImportError.resourceLimit(InterfaceLocalization.text("展开后的文件总量过大")) }

            let archivePath = try decodeName(rawName, flags: flags)
            // Keep archivePath in ZIPFoundation's decoding for entry identity checks.
            // macOS archives often omit bit 11 despite using valid UTF-8 bytes.
            var path = String(data: rawName, encoding: .utf8) ?? archivePath
            if let unicode = extra[0x7075] {
                guard unicode.count >= 5 else { throw invalid(InterfaceLocalization.text("Unicode 文件名字段被截断")) }
                if unicode[0] == 1, try unicode.u32(1) == ZIPImportCRC32.checksum(rawName) {
                    guard let decoded = String(data: unicode.dropFirst(5), encoding: .utf8) else { throw invalid(InterfaceLocalization.text("Unicode 文件名无效")) }
                    path = decoded
                    if flags & 0x0800 != 0, path != archivePath { throw invalid(InterfaceLocalization.text("Unicode 文件名与 UTF-8 文件名不一致")) }
                }
            }
            let attributes = try central.u32(cursor + 38), mode = (attributes >> 16) & 0xf000
            if mode != 0 && mode != 0x8000 && mode != 0x4000 {
                throw ZIPImportError.unsupportedArchive(InterfaceLocalization.text("符号链接或特殊文件"))
            }
            let isDirectory = archivePath.hasSuffix("/") || mode == 0x4000 || attributes & 0x10 != 0
            guard path.hasSuffix("/") == archivePath.hasSuffix("/") else { throw invalid(InterfaceLocalization.text("目录文件名不一致")) }
            if isDirectory && (uncompressed != 0 || compressed != 0) { throw invalid(InterfaceLocalization.text("目录条目包含数据")) }
            let relative = try ZIPImportPathPolicy.validated(path, isDirectory: isDirectory, limits: limits)
            // Validate both spellings even when a Unicode extra field is authoritative.
            _ = try ZIPImportPathPolicy.validated(archivePath, isDirectory: isDirectory, limits: limits)
            let entry = ZIPArchiveEntry(archivePath: archivePath, relativePath: relative, isDirectory: isDirectory,
                compressedBytes: compressed, uncompressedBytes: uncompressed, crc32: crc,
                compressionMethod: method, localHeaderOffset: offset)
            let spanEnd = try validateLocal(entry, rawName: rawName, flags: flags, version: version,
                                            reader: reader, centralOffset: cdOffset)
            spans.append((offset, spanEnd)); entries.append(entry); cursor = next
        }
        guard cursor == central.count else { throw invalid(InterfaceLocalization.text("目录条目数量与索引长度不一致")) }
        let ordered = spans.sorted { $0.0 < $1.0 }
        for index in 1..<ordered.count where ordered[index].0 < ordered[index - 1].1 {
            throw invalid(InterfaceLocalization.text("文件数据范围相互重叠"))
        }
        try ZIPImportPathPolicy.validateTargets(entries)
        return ZIPArchiveManifest(entries: entries, archiveBytes: reader.size,
                                  totalUncompressedBytes: total, usesZIP64: hasZIP64)
    }

    private static func validateLocal(_ entry: ZIPArchiveEntry, rawName: Data, flags: UInt16, version: UInt16,
                                      reader: ZIPReader, centralOffset: UInt64) throws -> UInt64 {
        let header = try reader.read(entry.localHeaderOffset, 30)
        guard try header.u32(0) == 0x04034b50, try header.u16(6) == flags,
              try header.u16(8) == entry.compressionMethod else { throw invalid(InterfaceLocalization.text("本地文件头与目录不一致")) }
        try validateFlags(try header.u16(6), method: header.u16(8), version: header.u16(4))
        let nameCount = Int(try header.u16(26)), extraCount = Int(try header.u16(28))
        let variable = try reader.read(add(entry.localHeaderOffset, 30), nameCount + extraCount)
        guard variable.prefix(nameCount) == rawName else { throw invalid(InterfaceLocalization.text("本地文件名与目录不一致")) }
        let extra = try extras(variable.subdata(in: nameCount..<variable.count))
        let start = try add(entry.localHeaderOffset, UInt64(30 + nameCount + extraCount))
        var end = try add(start, entry.compressedBytes)
        guard end <= centralOffset else { throw invalid(InterfaceLocalization.text("文件数据越过中央目录")) }
        let compressed32 = try header.u32(18), uncompressed32 = try header.u32(22)
        var zOffset = 0
        func size(_ raw: UInt32) throws -> UInt64 {
            if raw != 0xffffffff { return UInt64(raw) }
            defer { zOffset += 8 }
            return try (extra[1] ?? Data()).u64(zOffset)
        }
        let localUncompressed = try size(uncompressed32), localCompressed = try size(compressed32)
        if flags & 8 == 0 {
            guard try header.u32(14) == entry.crc32, localUncompressed == entry.uncompressedBytes,
                  localCompressed == entry.compressedBytes else { throw invalid(InterfaceLocalization.text("文件大小或校验值与目录不一致")) }
        } else {
            guard (try header.u32(14) == 0 || header.u32(14) == entry.crc32),
                  (localUncompressed == 0 || localUncompressed == entry.uncompressedBytes),
                  (localCompressed == 0 || localCompressed == entry.compressedBytes) else { throw invalid(InterfaceLocalization.text("文件描述符前的大小不一致")) }
            let wide = version >= 45 || extra[1] != nil
            let bytes = try reader.read(end, Int(min(centralOffset - end, wide ? 24 : 16)))
            let signature = try bytes.u32(0) == 0x08074b50
            let offset = signature ? 4 : 0
            let crc = try bytes.u32(offset)
            let compressed = wide ? try bytes.u64(offset + 4) : UInt64(try bytes.u32(offset + 4))
            let uncompressed = wide ? try bytes.u64(offset + 12) : UInt64(try bytes.u32(offset + 8))
            guard crc == entry.crc32, compressed == entry.compressedBytes, uncompressed == entry.uncompressedBytes else {
                throw invalid(InterfaceLocalization.text("文件描述符与中央目录不一致"))
            }
            end = try add(end, UInt64(offset + (wide ? 20 : 12)))
        }
        return end
    }

    private static func validateFlags(_ flags: UInt16, method: UInt16, version: UInt16) throws {
        if flags & 0x2041 != 0 { throw ZIPImportError.unsupportedArchive(InterfaceLocalization.text("加密或密码 ZIP；请先解密后再导入")) }
        guard flags & ~UInt16(0x080e) == 0, version <= 45, method == 0 || method == 8 else {
            throw ZIPImportError.unsupportedArchive(InterfaceLocalization.text("仅支持普通 Store/Deflate ZIP"))
        }
    }

    private static func extras(_ data: Data) throws -> [UInt16: Data] {
        var result: [UInt16: Data] = [:], cursor = 0
        while cursor < data.count {
            let kind = try data.u16(cursor), length = Int(try data.u16(cursor + 2))
            guard cursor + 4 + length <= data.count, result[kind] == nil else { throw invalid(InterfaceLocalization.text("附加字段损坏或重复")) }
            let value = data.subdata(in: (cursor + 4)..<(cursor + 4 + length))
            if kind == 0x9901 { throw ZIPImportError.unsupportedArchive(InterfaceLocalization.text("AES 密码 ZIP")) }
            if kind == 0x756e || (kind == 0x000d && length > 12) {
                throw ZIPImportError.unsupportedArchive(InterfaceLocalization.text("链接或特殊 UNIX 文件字段"))
            }
            result[kind] = value; cursor += 4 + length
        }
        return result
    }

    private static func decodeName(_ data: Data, flags: UInt16) throws -> String {
        let encoding: String.Encoding = flags & 0x0800 != 0 ? .utf8 :
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x400)))
        guard let name = String(data: data, encoding: encoding), !name.isEmpty else {
            throw ZIPImportError.unsupportedArchive(InterfaceLocalization.text("文件名编码无法读取；请使用 UTF-8 文件名重新打包"))
        }
        return name
    }
    private static func splitArchive() -> ZIPImportError { .unsupportedArchive(InterfaceLocalization.text("分卷 ZIP；请先合并为单个 ZIP")) }
    private static func invalid(_ reason: String) -> ZIPImportError { .invalidArchive(reason) }
    private static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw invalid(InterfaceLocalization.text("长度或偏移溢出")) }
        return sum
    }
}

private final class ZIPReader {
    let handle: FileHandle
    let size: UInt64
    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize, bytes >= 0 else {
            throw ZIPImportError.invalidArchive(InterfaceLocalization.text("请选择普通 ZIP 文件"))
        }
        size = UInt64(bytes); handle = try FileHandle(forReadingFrom: url)
    }
    deinit { try? handle.close() }
    func read(_ offset: UInt64, _ count: Int) throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
            throw ZIPImportError.invalidArchive(InterfaceLocalization.text("读取范围超出压缩包"))
        }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw ZIPImportError.invalidArchive(InterfaceLocalization.text("压缩包被截断")) }
        return data
    }
}

private extension Data {
    func uint(_ offset: Int, _ width: Int) throws -> UInt64 {
        guard offset >= 0, offset <= count, width <= count - offset else { throw ZIPImportError.invalidArchive(InterfaceLocalization.text("字段被截断")) }
        var value: UInt64 = 0
        for i in 0..<width { value |= UInt64(self[startIndex + offset + i]) << (i * 8) }
        return value
    }
    func u16(_ offset: Int) throws -> UInt16 { UInt16(try uint(offset, 2)) }
    func u32(_ offset: Int) throws -> UInt32 { UInt32(try uint(offset, 4)) }
    func u64(_ offset: Int) throws -> UInt64 { try uint(offset, 8) }
}
