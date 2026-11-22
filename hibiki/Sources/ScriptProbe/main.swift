import Foundation
import PDFKit
import HibikiCore

// 用法：ScriptProbe <台本路径>
// 打印解析结果，用来验证真实台本能不能被正确切开

guard CommandLine.arguments.count > 1 else {
    print("用法: ScriptProbe <台本文件>")
    exit(1)
}
let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)

var text = ""
if url.pathExtension.lowercased() == "pdf" {
    guard let doc = PDFDocument(url: url) else { print("打不开 PDF"); exit(1) }
    for i in 0..<doc.pageCount {
        if let page = doc.page(at: i), let s = page.string {
            text += s + "\n"
        }
    }
} else {
    let data = try Data(contentsOf: url)
    text = SubtitleTextDecoder.decode(data: data) ?? ""
}

print("原始文本: \(text.count) 字")

// 先看是不是合集台本
let sections = ScriptSectioner.split(text)
print("切分出段落: \(sections.count)")
for section in sections {
    print("  [\(section.displayName)] \(section.lines.count) 句")
}
if sections.count > 1 {
    print("--- 合集台本：按轨号匹配 ---")
    for name in ["Tr1_a.wav", "Tr2_b.wav", "Tr3_c.wav"] {
        if let number = ScriptSectioner.trackNumber(fromFileName: name),
           let matched = ScriptSectioner.section(forTrackNumber: number, in: sections) {
            print("  \(name) → 第\(number)轨 · \(matched.title)")
        }
    }
    exit(0)
}

let lines = ScriptParser.parse(text)
print("解析出台词: \(lines.count) 行")

let withSpeaker = lines.filter { $0.speaker != nil }
print("识别出说话人: \(withSpeaker.count) 行")
for line in withSpeaker {
    print("  → [\(line.speaker ?? "?")] \(String(line.text.prefix(40)))")
}

print("--- 前 12 行 ---")
for line in lines.prefix(12) {
    let speaker = line.speaker.map { "[\($0)] " } ?? ""
    print("\(line.index): \(speaker)\(String(line.text.prefix(50)))")
}

print("--- 后 5 行 ---")
for line in lines.suffix(5) {
    let speaker = line.speaker.map { "[\($0)] " } ?? ""
    print("\(line.index): \(speaker)\(String(line.text.prefix(50)))")
}

let totalChars = lines.reduce(0) { $0 + ScriptNormalizer.normalizedCharacters($1.text).count }
print("--- 总有效字数: \(totalChars) ---")

// 模拟一段 10 分钟的日语识别结果（每 1.5 秒一个词），验证跨语言对齐能跑
var fakeTokens: [TimedToken] = []
var t = 1000
for i in 0..<400 {
    fakeTokens.append(TimedToken(text: "あ", startMS: t, endMS: t + 1200))
    t += (i % 7 == 0) ? 1800 : 1300
}
let aligned = CrossLanguageAligner.align(
    scriptLines: ScriptParser.alignableLines(lines),
    tokens: fakeTokens
)
let cues = ScriptToCues.build(aligned: aligned, totalDurationMS: t)
print("跨语言对齐: 生成 \(cues.count) 条字幕")
print("时间范围: \(cues.first?.startMS ?? 0)ms → \(cues.last?.endMS ?? 0)ms")
print("--- 前 5 条 ---")
for cue in cues.prefix(5) {
    print("  [\(SubtitleTime.clock(cue.startMS)) → \(SubtitleTime.clock(cue.endMS))] \(String(cue.text.prefix(40)))")
}
