#if DEBUG
import Foundation
import UIKit

/// 调试用：在 App 沙盒里造一个**贴近真实作品结构**的示例库。
///
/// 只在带 `-seedLibrary` 启动参数时运行。生成的是真的 WAV / PNG / PDF，
/// 所以扫描、变体归并、分类、封面台本挑选、时长探测全都会被真实执行。
enum DebugSeed {

    static let rootFolderName = "サンプル音声ライブラリ"

    static func makeSampleLibrary() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let root = documents.appendingPathComponent(rootFolderName, isDirectory: true)

        if FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // ① 一个"完整形态"的作品：正片 + 特典 + 语音消息 + 闲聊 + 台本 + 封面
        let mainWork = root.appendingPathComponent("[サークルA] 甘い夜の囁き RJ01234567", isDirectory: true)
        try buildRichWork(at: mainWork)

        // ② 一个"没有任何子文件夹"的作品：音频直接放在所选目录里
        //    这一条专门用来验证"选中的文件夹内没有子文件夹"的情况
        let flat = root.appendingPathComponent("平铺作品_没有子文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: flat, withIntermediateDirectories: true)
        try writeSilentWAV(to: flat.appendingPathComponent("01. 朝の声.wav"), seconds: 18, frequency: 260)
        try writeSilentWAV(to: flat.appendingPathComponent("02. 夜の声.wav"), seconds: 22, frequency: 290)
        try writeCoverPNG(to: flat.appendingPathComponent("cover.png"), title: "Flat",
                          hue: (0.45, 0.28, 0.55))

        // ③ 一个只有正片的简单作品
        let simple = root.appendingPathComponent("雨の日の記憶", isDirectory: true)
        try FileManager.default.createDirectory(at: simple, withIntermediateDirectories: true)
        try writeSilentWAV(to: simple.appendingPathComponent("01. 雨音.wav"), seconds: 25, frequency: 300)
        try writeSilentWAV(to: simple.appendingPathComponent("02. 想い出.wav"), seconds: 20, frequency: 340)
        try writeCoverPNG(
            to: simple.appendingPathComponent("cover.png"),
            title: "Vol.2",
            hue: (0.24, 0.38, 0.62)
        )

        return root
    }

    /// 只生成"一个没有任何子文件夹的目录"，用于复现"选中目录里没有子文件夹"的场景
    static func makeFlatOnlyFolder() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let root = documents.appendingPathComponent("平铺单作品测试", isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeSilentWAV(to: root.appendingPathComponent("01. 一幕.wav"), seconds: 15, frequency: 240)
        try writeSilentWAV(to: root.appendingPathComponent("02. 二幕.wav"), seconds: 20, frequency: 270)
        try writeCoverPNG(to: root.appendingPathComponent("cover.png"), title: "Flat",
                          hue: (0.30, 0.45, 0.35))
        return root
    }

    // MARK: - 完整作品

    private static func buildRichWork(at workDir: URL) throws {
        let fm = FileManager.default

        // 正片：本編SEあり/wav/Tr1..Tr3
        let mainDir = workDir.appendingPathComponent("本編SEあり/wav", isDirectory: true)
        try fm.createDirectory(at: mainDir, withIntermediateDirectories: true)
        try writeSilentWAV(to: mainDir.appendingPathComponent("Tr1_プロローグ.wav"), seconds: 45, frequency: 220)
        // 示例字幕：日文原文 + 中文译文两份，验证自动匹配、配对与合并
        try writeSRT(
            to: mainDir.appendingPathComponent("Tr1_プロローグ.ja.srt"),
            lines: [
                (2, 6, "……ねえ、聞こえてる？", "……喂，你听得见吗？"),
                (8, 13, "こんな夜更けに、どうしたの", "这么晚了，怎么了？"),
                (15, 20, "あ、そこはだめ……", "啊，那里不行……"),
                (23, 28, "ちょっと、恥ずかしいよ", "等一下，好害羞啊"),
                (31, 36, "でも、嫌じゃない……", "可是，并不讨厌……"),
                (39, 44, "もう少しだけ、こうしていよう", "再这样待一会儿吧")
            ]
        )
        try writeSilentWAV(to: mainDir.appendingPathComponent("Tr2_本編.wav"), seconds: 60, frequency: 250)
        try writeSilentWAV(to: mainDir.appendingPathComponent("Tr3_エピローグ.wav"), seconds: 40, frequency: 280)

        // 同时提供 mp3 版本，用来验证变体归并
        let mainMp3 = workDir.appendingPathComponent("本編SEあり/mp3", isDirectory: true)
        try fm.createDirectory(at: mainMp3, withIntermediateDirectories: true)
        for name in ["Tr1_プロローグ", "Tr2_本編", "Tr3_エピローグ"] {
            try writeSilentWAV(to: mainMp3.appendingPathComponent("\(name).mp3"), seconds: 20, frequency: 200)
        }

        // 特典
        let bonusDir = workDir.appendingPathComponent("【購入特典】後日談", isDirectory: true)
        try fm.createDirectory(at: bonusDir, withIntermediateDirectories: true)
        try writeSilentWAV(to: bonusDir.appendingPathComponent("後日談_朝の支度.wav"), seconds: 35, frequency: 320)

        // 语音消息
        let voiceDir = workDir.appendingPathComponent("【早期購入特典】ボイスメッセージ/wav", isDirectory: true)
        try fm.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        try writeSilentWAV(to: voiceDir.appendingPathComponent("01_おはよう.wav"), seconds: 10, frequency: 400)
        try writeSilentWAV(to: voiceDir.appendingPathComponent("02_おやすみ.wav"), seconds: 12, frequency: 420)
        try writeSilentWAV(to: voiceDir.appendingPathComponent("03_俺だけ.wav"), seconds: 9, frequency: 440)

        // 闲聊
        let talkDir = workDir.appendingPathComponent("【お気に入り特典】フリートーク", isDirectory: true)
        try fm.createDirectory(at: talkDir, withIntermediateDirectories: true)
        try writeSilentWAV(to: talkDir.appendingPathComponent("フリートーク.wav"), seconds: 30, frequency: 360)

        // Readme
        try "これはサンプル作品の Readme です。\n実際の作品にも必ず入っています。"
            .write(to: workDir.appendingPathComponent("Readme.txt"), atomically: true, encoding: .utf8)

        // 台本：简体和繁体各一份，验证"优先简体"
        try writeSimplePDF(
            to: workDir.appendingPathComponent("Mainstory_簡体字台本.pdf"),
            title: "简体字台本（示例）"
        )
        try writeSimplePDF(
            to: workDir.appendingPathComponent("Mainstory_繁体字台本.pdf"),
            title: "繁體字台本（示例）"
        )

        // 封面
        try writeCoverPNG(
            to: workDir.appendingPathComponent("ノンテキストキービジュアル.png"),
            title: "Vol.1",
            hue: (0.62, 0.30, 0.42)
        )
    }

    // MARK: - 字幕

    /// 写一份示例字幕：`xxx.ja.srt` 原文 + `xxx.zh.srt` 译文
    static func writeSRT(
        to url: URL,
        lines: [(start: Double, end: Double, ja: String, zh: String)]
    ) throws {
        var original = ""
        var translated = ""
        for (index, line) in lines.enumerated() {
            let number = index + 1
            let range = "\(srtTime(line.start)) --> \(srtTime(line.end))"
            original += "\(number)\n\(range)\n\(line.ja)\n\n"
            translated += "\(number)\n\(range)\n\(line.zh)\n\n"
        }
        try original.data(using: .utf8)?.write(to: url)
        // 从 "Tr1_プロローグ.ja" 里去掉语言后缀，得到 "Tr1_プロローグ.zh.srt"
        var base = (url.lastPathComponent as NSString).deletingPathExtension
        if base.hasSuffix(".ja") { base = String(base.dropLast(3)) }
        let zhURL = url.deletingLastPathComponent()
            .appendingPathComponent(base)
            .appendingPathExtension("zh.srt")
        try translated.data(using: .utf8)?.write(to: zhURL)
    }

    private static func srtTime(_ seconds: Double) -> String {
        let total = Int((seconds * 1000).rounded())
        let h = total / 3_600_000
        let m = (total % 3_600_000) / 60_000
        let s = (total % 60_000) / 1000
        let ms = total % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    // MARK: - WAV

    static func writeSilentWAV(to url: URL, seconds: Double, frequency: Double) throws {
        let sampleRate = 22_050
        let sampleCount = max(1, Int(Double(sampleRate) * seconds))
        let amplitude = 0.18

        var samples = Data(capacity: sampleCount * 2)
        for i in 0..<sampleCount {
            let envelope = 0.5 + 0.5 * sin(Double(i) / Double(sampleRate) * 0.7)
            let value = sin(2.0 * Double.pi * frequency * Double(i) / Double(sampleRate)) * amplitude * envelope
            let intValue = Int16(max(-32767, min(32767, value * 32767)))
            Swift.withUnsafeBytes(of: intValue.littleEndian) { samples.append(contentsOf: $0) }
        }

        var data = Data()
        let dataSize = UInt32(samples.count)
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: dataSize + 36)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(sampleRate * 2))
        data.append(littleEndian: UInt16(2))
        data.append(littleEndian: UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: dataSize)
        data.append(samples)
        try data.write(to: url)
    }

    // MARK: - PNG

    static func writeCoverPNG(to url: URL, title: String, hue: (CGFloat, CGFloat, CGFloat)) throws {
        let size = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)

        let image = renderer.image { context in
            let base = UIColor(red: hue.0, green: hue.1, blue: hue.2, alpha: 1.0)
            let lighter = UIColor(
                red: min(1, hue.0 + 0.25), green: min(1, hue.1 + 0.25), blue: min(1, hue.2 + 0.25), alpha: 1.0
            )
            let colors = [base.cgColor, lighter.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(
                    gradient, start: .zero,
                    end: CGPoint(x: size.width, y: size.height), options: []
                )
            }

            context.cgContext.setFillColor(UIColor.white.withAlphaComponent(0.12).cgColor)
            context.cgContext.fillEllipse(in: CGRect(x: 380, y: 80, width: 260, height: 260))
            context.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.08).cgColor)
            context.cgContext.fillEllipse(in: CGRect(x: -60, y: 380, width: 300, height: 300))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 40, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            let text = title as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                in: CGRect(x: 0, y: size.height - textSize.height - 70,
                           width: size.width, height: textSize.height),
                withAttributes: attributes
            )
        }

        guard let png = image.pngData() else {
            throw NSError(domain: "DebugSeed", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "PNG 编码失败"])
        }
        try png.write(to: url)
    }

    // MARK: - PDF

    /// 生成一个最小但合法的单页 PDF（用于验证台本识别，以及后续 PDF 阅读）
    static func writeSimplePDF(to url: URL, title: String) throws {
        let escaped = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")

        let content = """
        BT /F1 24 Tf 72 700 Td (\(escaped)) Tj ET
        BT /F1 14 Tf 72 660 Td (Sample script for PDF extraction test.) Tj ET
        """

        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        objects.append(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] "
            + "/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>"
        )
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")

        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xrefStart = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefStart)\n%%EOF\n"

        try pdf.write(to: url, atomically: true, encoding: .utf8)
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func append(littleEndian value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

#endif
