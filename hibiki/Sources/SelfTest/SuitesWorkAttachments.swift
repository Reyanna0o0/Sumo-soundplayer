import Foundation
import HibikiCore

func runWorkAttachmentSuites(_ h: Harness) {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func write(_ bytes: Data = Data("fixture".utf8), to path: String, under root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    h.suite("作品附件：真实目录枚举") {
        h.test("复制整个作品后保留嵌套附件，音频和字幕不冒充附件") {
            do {
                let root = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let original = root.appendingPathComponent("original")
                let copy = root.appendingPathComponent("copy")
                let paths = ["本篇/01.wav", "字幕/01.wav.vtt", "图片/第10张.PNG", "图片/第2张.jpg",
                             "台本/扫描版.pdf", "特典/小说.txt", "视频/特典.mp4", "视频/额外.mkv", "说明.md"]
                for path in paths { try write(to: path, under: original) }
                try FileManager.default.copyItem(at: original, to: copy)
                let found = try WorkAttachmentFinder.find(in: copy)
                h.expectEqual(found.count, 7, "附件数量")
                h.expect(found.contains { $0.relativePath == "台本/扫描版.pdf" && $0.kind == .pdf }, "扫描版 PDF 不依赖文字提取")
                h.expect(found.contains { $0.fileExtension == "mkv" && $0.kind == .video }, "列出视频不等于保证能播放")
                h.expect(!found.contains { ["wav", "vtt"].contains($0.fileExtension) }, "附件与音轨字幕分离")
                h.expectEqual(found.filter { $0.kind == .image }.map(\.fileName), ["第2张.jpg", "第10张.PNG"], "图片自然排序")
                for attachment in found {
                    let url = WorkAttachmentFinder.fileURL(for: attachment, in: copy)
                    h.expectNotNil(url, "可安全解析相对路径")
                    h.expectEqual(try Data(contentsOf: url!), Data("fixture".utf8), "复制后字节一致")
                }
                h.expect(FileManager.default.fileExists(atPath: original.appendingPathComponent(paths[0]).path), "原文件保留")
            } catch { h.expect(false, "枚举失败：\(error)") }
        }
        h.test("旧目录无需迁移，新附件和删除附件在下次枚举生效") {
            do {
                let root = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                try write(to: "01.mp3", under: root)
                h.expectEqual(try WorkAttachmentFinder.find(in: root).count, 0, "旧音频目录")
                try write(Data(), to: "小说/空白.txt", under: root)
                try write(Data([1]), to: "图片/小图.png", under: root)
                h.expectEqual(try WorkAttachmentFinder.find(in: root).count, 2, "小文件没有音频大小门槛")
                try FileManager.default.removeItem(at: root.appendingPathComponent("小说/空白.txt"))
                h.expectEqual(try WorkAttachmentFinder.find(in: root).count, 1, "删除不留陈旧记录")
            } catch { h.expect(false, "动态枚举失败：\(error)") }
        }
        h.test("相同文件名保留所在目录，隐藏和符号链接不读取") {
            do {
                let root = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                try write(to: "A/说明.txt", under: root)
                try write(to: "B/说明.txt", under: root)
                try write(to: ".隐藏/说明.txt", under: root)
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"),
                                                          withDestinationURL: root.appendingPathComponent("A/说明.txt"))
                h.expectEqual(try WorkAttachmentFinder.find(in: root).map(\.relativePath),
                              ["A/说明.txt", "B/说明.txt"], "不合并重名、不跟随链接")
            } catch { h.expect(false, "隔离检查失败：\(error)") }
        }
        h.test("空目录有效，源目录失效明确报错") {
            do {
                let root = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                h.expectEqual(try WorkAttachmentFinder.find(in: root), [], "空目录")
                do {
                    _ = try WorkAttachmentFinder.find(in: root.appendingPathComponent("missing"))
                    h.expect(false, "失效目录不能当作空附件")
                } catch { h.expect(true, "目录失效报告错误") }
                try write(to: "not-directory.txt", under: root)
                do {
                    _ = try WorkAttachmentFinder.find(in: root.appendingPathComponent("not-directory.txt"))
                    h.expect(false, "普通文件不是目录")
                } catch { h.expect(true, "目录类型错误报告错误") }
            } catch { h.expect(false, "错误态检查失败：\(error)") }
        }
        h.test("文件路径不能越过授权目录") {
            let root = URL(fileURLWithPath: "/tmp/attachment-root", isDirectory: true)
            for path in ["../private.txt", "/private.txt", "A/../../private.txt", "A//private.txt"] {
                let attachment = WorkAttachment(relativePath: path, kind: .text, byteCount: 1)
                h.expectNil(WorkAttachmentFinder.fileURL(for: attachment, in: root), "拒绝 \(path)")
            }
            h.expect(WorkAttachmentFinder.isLegacyFormatFolder("wav"), "兼容一级 wav")
            h.expect(WorkAttachmentFinder.isLegacyFormatFolder("MP3"), "兼容大写 MP3")
            h.expect(!WorkAttachmentFinder.isLegacyFormatFolder("作品/wav"), "不扩展嵌套目录")
            h.expect(!WorkAttachmentFinder.isLegacyFormatFolder("本篇_wav"), "不猜测父目录权限")
            h.expect(!WorkAttachmentFinder.isLegacyFormatFolder(".."), "不能越界")
        }
        h.test("目录读取权限失效不能伪装成空附件") {
            do {
                let root = try temporaryDirectory()
                defer {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
                    try? FileManager.default.removeItem(at: root)
                }
                try write(to: "小说.txt", under: root)
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
                do {
                    _ = try WorkAttachmentFinder.find(in: root)
                    h.expect(false, "读取无权限目录应失败")
                } catch { h.expect(true, "权限失效报告错误") }
            } catch { h.expect(false, "权限失效检查失败：\(error)") }
        }
    }

    h.suite("作品附件：文字读取") {
        h.test("中日文 UTF-8、UTF-16 与显式亚洲编码") {
            let text = "第一章\nこんにちは。\n文字小说。"
            h.expectEqual(WorkAttachmentTextEncoding.automatic.decode(Data(text.utf8)), text, "UTF-8 自动")
            h.expectEqual(WorkAttachmentTextEncoding.utf8.decode(Data(text.utf8)), text, "UTF-8 指定")
            let utf16 = text.data(using: .utf16)!
            h.expectEqual(WorkAttachmentTextEncoding.automatic.decode(utf16), text, "UTF-16 BOM 自动")
            h.expectEqual(WorkAttachmentTextEncoding.utf16.decode(utf16), text, "UTF-16 指定")
            for (encoding, value, stringEncoding) in [
                (WorkAttachmentTextEncoding.shiftJIS, "日本語の小説", String.Encoding.shiftJIS),
                (.gb18030, "简体中文小说", SubtitleTextDecoder.gb18030)
            ] {
                let data = value.data(using: stringEncoding)!
                h.expectEqual(encoding.decode(data), value, "显式 \(encoding.title)")
            }
            h.expectEqual(WorkAttachmentTextEncoding.automatic.decode(Data()), "", "空文本")
            h.expectNil(WorkAttachmentTextEncoding.utf8.decode(Data([0xFF, 0xFF])), "错误编码有错误态")
        }
        h.test("大文件拒绝全文加载，普通文本保留换行") {
            do {
                let root = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                try write(Data("第一行\n第二行".utf8), to: "novel.txt", under: root)
                h.expectEqual(try WorkAttachmentTextReader.read(from: root.appendingPathComponent("novel.txt"), encoding: .automatic),
                              "第一行\n第二行", "原始正文")
                try write(Data(repeating: 65, count: WorkAttachmentTextReader.maximumByteCount + 1), to: "large.txt", under: root)
                do {
                    _ = try WorkAttachmentTextReader.read(from: root.appendingPathComponent("large.txt"), encoding: .automatic)
                    h.expect(false, "超大文件应明确拒绝")
                } catch WorkAttachmentTextReader.Failure.tooLarge {
                    h.expect(true, "超大文件限制生效")
                }
            } catch { h.expect(false, "文字文件检查失败：\(error)") }
        }
    }
}
