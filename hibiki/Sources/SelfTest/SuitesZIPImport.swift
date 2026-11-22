import Foundation
import HibikiCore

private struct ZIPTestEntry {
    var name: String
    var data = Data("neutral fixture".utf8)
    var flags: UInt16 = 0x0800
    var method: UInt16 = 0
    var attributes: UInt32 = 0
    var extra = Data()
    var localName: String?
}

private extension Data {
    mutating func zipLE(_ value: UInt64, _ bytes: Int) {
        for index in 0..<bytes { append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
    }
    mutating func zipPatch(_ offset: Int, _ value: UInt64, _ bytes: Int) {
        for index in 0..<bytes { self[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }
}

/// Builds ordinary stored fixtures and ZIP64/data-descriptor variants without an archive dependency.
private func zipFixture(_ entries: [ZIPTestEntry], wide: Bool = false, descriptor: Bool = false) -> Data {
    var output = Data(), directory = Data()
    for entry in entries {
        let name = Data(entry.name.utf8), localName = Data((entry.localName ?? entry.name).utf8)
        let offset = UInt64(output.count), size = UInt64(entry.data.count), crc = UInt64(ZIPImportCRC32.checksum(entry.data))
        let flags = UInt64(entry.flags | (descriptor ? 8 : 0)), version: UInt64 = wide ? 45 : 20
        var localExtra = entry.extra, centralExtra = entry.extra
        if wide {
            localExtra.zipLE(1, 2); localExtra.zipLE(16, 2); localExtra.zipLE(size, 8); localExtra.zipLE(size, 8)
            centralExtra.zipLE(1, 2); centralExtra.zipLE(24, 2)
            centralExtra.zipLE(size, 8); centralExtra.zipLE(size, 8); centralExtra.zipLE(offset, 8)
        }
        output.zipLE(0x04034b50, 4); output.zipLE(version, 2); output.zipLE(flags, 2)
        output.zipLE(UInt64(entry.method), 2); output.zipLE(0, 4); output.zipLE(descriptor ? 0 : crc, 4)
        output.zipLE(wide ? 0xffffffff : (descriptor ? 0 : size), 4)
        output.zipLE(wide ? 0xffffffff : (descriptor ? 0 : size), 4)
        output.zipLE(UInt64(localName.count), 2); output.zipLE(UInt64(localExtra.count), 2)
        output.append(localName); output.append(localExtra); output.append(entry.data)
        if descriptor {
            output.zipLE(0x08074b50, 4); output.zipLE(crc, 4)
            output.zipLE(size, wide ? 8 : 4); output.zipLE(size, wide ? 8 : 4)
        }
        directory.zipLE(0x02014b50, 4); directory.zipLE(0x0314, 2); directory.zipLE(version, 2)
        directory.zipLE(flags, 2); directory.zipLE(UInt64(entry.method), 2); directory.zipLE(0, 4)
        directory.zipLE(crc, 4); directory.zipLE(wide ? 0xffffffff : size, 4); directory.zipLE(wide ? 0xffffffff : size, 4)
        directory.zipLE(UInt64(name.count), 2); directory.zipLE(UInt64(centralExtra.count), 2)
        directory.zipLE(0, 2); directory.zipLE(0, 2); directory.zipLE(0, 2)
        directory.zipLE(UInt64(entry.attributes), 4); directory.zipLE(wide ? 0xffffffff : offset, 4)
        directory.append(name); directory.append(centralExtra)
    }
    let start = UInt64(output.count), size = UInt64(directory.count), count = UInt64(entries.count)
    output.append(directory)
    if wide {
        let footer = UInt64(output.count)
        output.zipLE(0x06064b50, 4); output.zipLE(44, 8); output.zipLE(45, 2); output.zipLE(45, 2)
        output.zipLE(0, 4); output.zipLE(0, 4); output.zipLE(count, 8); output.zipLE(count, 8)
        output.zipLE(size, 8); output.zipLE(start, 8)
        output.zipLE(0x07064b50, 4); output.zipLE(0, 4); output.zipLE(footer, 8); output.zipLE(1, 4)
    }
    output.zipLE(0x06054b50, 4); output.zipLE(0, 2); output.zipLE(0, 2)
    output.zipLE(wide ? 0xffff : count, 2); output.zipLE(wide ? 0xffff : count, 2)
    output.zipLE(wide ? 0xffffffff : size, 4); output.zipLE(wide ? 0xffffffff : start, 4); output.zipLE(0, 2)
    return output
}

func runZIPImportSuites(_ h: Harness) {
    h.suite("普通 ZIP 导入边界（只读预检）") {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("simo-zip-fixtures-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        func inspect(_ data: Data, limits: ZIPImportLimits = .default,
                     check: () throws -> Void = {}) throws -> ZIPArchiveManifest {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(UUID().uuidString + ".zip")
            try data.write(to: url, options: .withoutOverwriting)
            return try ZIPArchiveInspector.inspect(at: url, limits: limits, checkCancellation: check)
        }
        func test(_ name: String, _ body: () throws -> Void) {
            h.test(name) { do { try body() } catch { h.expect(false, "意外错误：\(error)") } }
        }
        func reject(_ data: Data, _ label: String, limits: ZIPImportLimits = .default) {
            do { _ = try inspect(data, limits: limits); h.expect(false, "应拒绝：\(label)") }
            catch { h.expect(error is ZIPImportError, "\(label) 明确 ZIP 错误") }
        }
        test("保留中文日文目录和同名不同目录文件") {
            let items = [ZIPTestEntry(name: "作品/本編/01.wav"), ZIPTestEntry(name: "作品/特典/01.wav"),
                         ZIPTestEntry(name: "作品/台本/日本語.txt"), ZIPTestEntry(name: "空目录/", data: Data())]
            let result = try inspect(zipFixture(items))
            h.expectEqual(result.entries.map(\.relativePath), items.map { $0.name.hasSuffix("/") ? String($0.name.dropLast()) : $0.name })
            h.expectEqual(result.totalUncompressedBytes, UInt64(3 * items[0].data.count))
            h.expectEqual(result.entries.last?.isDirectory, true)
        }
        test("ZIP64 和带描述符的 ZIP 都完整核对") {
            for wide in [false, true] { for descriptor in [false, true] {
                let result = try inspect(zipFixture([ZIPTestEntry(name: "音频.wav")], wide: wide, descriptor: descriptor))
                h.expectEqual(result.usesZIP64, wide); h.expectEqual(result.entries.count, 1)
                h.expectEqual(result.entries[0].uncompressedBytes, 15)
            } }
        }
        test("CRC 标准向量") { h.expectEqual(ZIPImportCRC32.checksum(Data("123456789".utf8)), 0xcbf43926) }
        test("所有截断位置和尾部附加数据均拒绝") {
            let valid = zipFixture([ZIPTestEntry(name: "01.wav")])
            for length in 0..<valid.count { reject(Data(valid.prefix(length)), "截断\(length)") }
            var trailing = valid; trailing.append(0); reject(trailing, "尾部附加")
        }
        test("密码 ZIP 不能在首条或中间被静默跳过") {
            for position in 0..<3 {
                var items = (0..<3).map { ZIPTestEntry(name: "\($0).wav") }
                items[position].flags |= 1; reject(zipFixture(items), "加密\(position)")
            }
            var strong = ZIPTestEntry(name: "strong.wav"); strong.flags |= 0x40
            reject(zipFixture([strong]), "强加密")
        }
        test("分卷和不支持的压缩方法拒绝") {
            var split = zipFixture([ZIPTestEntry(name: "01.wav")]); split.zipPatch(split.count - 18, 1, 2)
            reject(split, "分卷")
            reject(zipFixture([ZIPTestEntry(name: "01.wav", method: 99)]), "AES/未知压缩")
            reject(zipFixture([ZIPTestEntry(name: "01.wav", method: 12)]), "bzip2")
        }
        test("绝对路径 父目录 反斜线 空段 控制字符均拒绝") {
            for path in ["../escape.wav", "/escape.wav", "C:/escape.wav", "a/../../escape.wav", "a\\escape.wav", "a//b.wav", "./a.wav", "a/./b.wav", "a\0.wav", "a\n.wav"] {
                reject(zipFixture([ZIPTestEntry(name: path)]), path)
            }
        }
        test("重复和Unicode 大小写及文件目录目标冲突拒绝") {
            for pair in [("a.wav", "a.wav"), ("A.wav", "a.wav"), ("é.wav", "e\u{301}.wav"),
                         ("a", "a/b.wav"), ("a/b.wav", "a"), ("A/1.wav", "a/2.wav"), ("a/", "a/")] {
                let items = [pair.0, pair.1].map { ZIPTestEntry(name: $0, data: $0.hasSuffix("/") ? Data() : Data([1])) }
                reject(zipFixture(items), "目标冲突")
            }
        }
        test("符号链接 特殊文件 硬链接字段拒绝") {
            for mode: UInt32 in [0xa000, 0x1000, 0x2000, 0x6000, 0xc000] {
                reject(zipFixture([ZIPTestEntry(name: "link", attributes: mode << 16)]), "特殊文件")
            }
            var field = Data(); field.zipLE(0x000d, 2); field.zipLE(13, 2); field.append(Data(repeating: 0, count: 13))
            reject(zipFixture([ZIPTestEntry(name: "hard", extra: field)]), "硬链接")
        }
        test("本地文件名不同 中央目录数量不同 校验值不同拒绝") {
            reject(zipFixture([ZIPTestEntry(name: "safe.wav", localName: "evil.wav")]), "名称差异")
            var counts = zipFixture([ZIPTestEntry(name: "01.wav")]); counts.zipPatch(counts.count - 12, 2, 2)
            reject(counts, "数量差异")
            var checksum = zipFixture([ZIPTestEntry(name: "01.wav")]); checksum.zipPatch(14, 1, 4)
            reject(checksum, "CRC 字段差异")
        }
        test("Unicode扩展字段校验并防止其路径越界") {
            func field(_ path: String) -> Data {
                var payload = Data([1]); payload.zipLE(UInt64(ZIPImportCRC32.checksum(Data("legacy.wav".utf8))), 4)
                payload.append(Data(path.utf8)); var result = Data()
                result.zipLE(0x7075, 2); result.zipLE(UInt64(payload.count), 2); result.append(payload); return result
            }
            let accepted = try inspect(zipFixture([ZIPTestEntry(name: "legacy.wav", flags: 0, extra: field("日本語.wav"))]))
            h.expectEqual(accepted.entries[0].archivePath, "legacy.wav")
            h.expectEqual(accepted.entries[0].relativePath, "日本語.wav")
            reject(zipFixture([ZIPTestEntry(name: "legacy.wav", flags: 0, extra: field("../escape.wav"))]), "Unicode 越界")
        }
        test("资源上限在提取之前拒绝") {
            let data = zipFixture([ZIPTestEntry(name: "a/b.wav"), ZIPTestEntry(name: "c.wav")])
            var limits = ZIPImportLimits.default; limits.maximumEntries = 1; reject(data, "数量", limits: limits)
            limits = .default; limits.maximumArchiveBytes = 1; reject(data, "输入", limits: limits)
            limits = .default; limits.maximumEntryBytes = 1; reject(data, "单个文件", limits: limits)
            limits = .default; limits.maximumUncompressedBytes = 20; reject(data, "总量", limits: limits)
            limits = .default; limits.maximumDepth = 1; reject(data, "深度", limits: limits)
            limits = .default; limits.maximumPathBytes = 3; reject(data, "路径", limits: limits)
            limits = .default; limits.maximumCentralDirectoryBytes = 1; reject(data, "索引", limits: limits)
        }
        test("取消在只读预检中传播") {
            do {
                _ = try inspect(zipFixture([ZIPTestEntry(name: "01.wav")]), check: { throw CancellationError() })
                h.expect(false, "取消不应成功")
            } catch { h.expect(error is CancellationError, "不把取消变成普通格式错误") }
        }
    }
}
