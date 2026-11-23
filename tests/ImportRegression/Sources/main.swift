import Foundation
import CoreFoundation
import HibikiCore
import ZIPFoundation

// Each test counts once, unlike the existing Harness's assertions + cases count.
var passed = 0, failed = 0
struct CheckFailure: Error { let message: String }
func require(_ value: Bool, _ message: String = "unexpected result") throws {
    if !value { throw CheckFailure(message: message) }
}
func test(_ name: String, _ body: () throws -> Void) {
    do { try body(); passed += 1; print("PASS \(name)") }
    catch { failed += 1; print("FAIL \(name): \(error)") }
}
func selected(_ path: String) -> SidecarSubtitleMatch {
    SubtitleSidecarFinder.find(audioFileName: "01.wav", candidatePaths: [path]).first ?? SidecarSubtitleMatch(path: path, format: .srt)
}
func pair(_ paths: [String], index: Int = 0) -> (primary: SidecarSubtitleMatch, secondary: SidecarSubtitleMatch?) {
    SubtitleSidecarFinder.importPair(for: selected(paths[index]), subtitlePaths: paths)
}
let ja = "/w/01.ja.srt", zh = "/w/01.zh.srt"
let riskMode = CommandLine.arguments.contains("--risk-probes")

if !riskMode {
    test("importPair ja+zh selects Japanese primary from either selected candidate") {
        for i in [0, 1] { let p = pair([ja, zh], index: i); try require(p.primary.path == ja && p.secondary?.path == zh) }
    }
    test("importPair preserves confidence and format") {
        let p = SubtitleSidecarFinder.importPair(for: .init(path: ja, format: .srt, languageHint: "ja", confidence: 0.96), subtitlePaths: [zh, ja])
        try require(p.primary.confidence == 0.96 && p.secondary?.confidence == 0.96 && p.secondary?.format == .srt)
    }
    test("importPair order-independent") {
        let a = pair([ja, zh]), b = pair([zh, ja]); try require(a.primary == b.primary && a.secondary == b.secondary)
    }
    test("importPair single language remains single") { try require(pair([ja]).secondary == nil) }
    test("importPair no language suffix remains single") { try require(pair(["/w/01.srt", ja, zh]).secondary == nil) }
    test("importPair different directories not combined") { try require(pair([ja, "/other/01.zh.srt"]).secondary == nil) }
    test("importPair different subtitle formats not combined") { try require(pair([ja, "/w/01.zh.vtt"]).secondary == nil) }
    test("importPair different base names not combined") { try require(pair([ja, "/w/02.zh.srt"]).secondary == nil) }
    test("importPair three languages ambiguous") { try require(pair([ja, zh, "/w/01.en.srt"]).secondary == nil) }
    test("importPair duplicate inputs conservative") { try require(pair([ja, zh, ja]).secondary == nil) }
    test("importPair same language case aliases not combined") { try require(pair([ja, "/w/01.JA.srt"]).secondary == nil) }
    test("importPair case-insensitive format suffix") { try require(pair([ja, "/w/01.zh.SRT"]).secondary?.path == "/w/01.zh.SRT") }
    test("importPair WAV-specific subtitles not paired with MP3-specific subtitles") {
        let p = pair(["/w/01.wav.ja.srt", "/w/01.mp3.zh.srt"]); try require(p.secondary == nil)
    }
    test("importMatches plus importPair same-directory happy path") {
        let matches = SubtitleSidecarFinder.importMatches(audioPaths: ["/w/01.wav"], subtitlePaths: [ja, zh])
        guard let s = matches["/w/01.wav"] else { throw CheckFailure(message: "missing owner") }
        let p = SubtitleSidecarFinder.importPair(for: s, subtitlePaths: [ja, zh]); try require(p.primary.path == ja && p.secondary?.path == zh)
    }
    test("selected audio variant retains shared bilingual ownership") {
        let tracks = ["/w/01.wav", "/w/01.mp3"]
        let matches = SubtitleSidecarFinder.importMatches(audioPaths: tracks, subtitlePaths: [ja, zh], selectedAudioPaths: [tracks[0]])
        try require(matches[tracks[0]] != nil && matches[tracks[1]] == nil)
        let p = SubtitleSidecarFinder.importPair(for: matches[tracks[0]]!, subtitlePaths: [ja, zh]); try require(p.secondary?.path == zh)
    }
    test("SE variants across directories remain ambiguous") {
        let matches = SubtitleSidecarFinder.importMatches(audioPaths: ["/w/SE/01.wav", "/w/noSE/01.wav"], subtitlePaths: [ja, zh], selectedAudioPaths: ["/w/SE/01.wav"])
        try require(matches.isEmpty)
    }
    test("paired SRT parser and merger preserves text translation and timing") {
        let primary = SubtitleParser.parse("1\n00:00:01,000 --> 00:00:02,000\nこんにちは", formatHint: .srt).cues
        let secondary = SubtitleParser.parse("1\n00:00:01,000 --> 00:00:02,000\n你好", formatHint: .srt).cues
        let result = SubtitleTranslationMerger.merge(primary: primary, secondary: secondary)
        try require(result.count == 1 && result[0].text == "こんにちは" && result[0].translatedText == "你好" && result[0].startMS == 1000 && result[0].endMS == 2000)
    }
}

extension Data {
    mutating func le(_ value: UInt64, _ bytes: Int) { for i in 0..<bytes { append(UInt8(truncatingIfNeeded: value >> (8*i))) } }
}
struct Entry {
    var raw: Data
    var flags: UInt16 = 0
    var extra = Data()
    var payload = Data("fixture".utf8)
}
func unicodeExtra(raw: Data, path: String, validCRC: Bool = true) -> Data {
    var payload = Data([1]); payload.le(UInt64(ZIPImportCRC32.checksum(raw)) ^ (validCRC ? 0 : 1), 4); payload.append(Data(path.utf8))
    var field = Data(); field.le(0x7075, 2); field.le(UInt64(payload.count), 2); field.append(payload); return field
}
func zipData(_ entries: [Entry]) -> Data {
    var output = Data(), central = Data()
    for e in entries {
        let offset = output.count, size = UInt64(e.payload.count), crc = UInt64(ZIPImportCRC32.checksum(e.payload))
        output.le(0x04034b50, 4); output.le(20, 2); output.le(UInt64(e.flags), 2); output.le(0, 2); output.le(0, 4)
        output.le(crc, 4); output.le(size, 4); output.le(size, 4); output.le(UInt64(e.raw.count), 2); output.le(UInt64(e.extra.count), 2)
        output.append(e.raw); output.append(e.extra); output.append(e.payload)
        central.le(0x02014b50, 4); central.le(20, 2); central.le(20, 2); central.le(UInt64(e.flags), 2); central.le(0, 2); central.le(0, 4)
        central.le(crc, 4); central.le(size, 4); central.le(size, 4); central.le(UInt64(e.raw.count), 2); central.le(UInt64(e.extra.count), 2)
        central.le(0, 2); central.le(0, 2); central.le(0, 2); central.le(0, 4); central.le(UInt64(offset), 4); central.append(e.raw); central.append(e.extra)
    }
    let offset = output.count; output.append(central)
    output.le(0x06054b50, 4); output.le(0, 2); output.le(0, 2); output.le(UInt64(entries.count), 2); output.le(UInt64(entries.count), 2)
    output.le(UInt64(central.count), 4); output.le(UInt64(offset), 4); output.le(0, 2); return output
}
let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("sumo-import-regression-" + UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: fixtures) }
func inspect(_ name: String, _ entries: [Entry]) throws -> ZIPArchiveManifest {
    let url = fixtures.appendingPathComponent(name + ".zip")
    try zipData(entries).write(to: url)
    return try ZIPArchiveInspector.inspect(at: url)
}
func reject(_ name: String, _ entries: [Entry]) throws {
    do { _ = try inspect(name, entries) } catch is ZIPImportError { return }
    throw CheckFailure(message: "unsafe/invalid ZIP accepted")
}
if !riskMode {
    for (id, name) in [("zh", "作品/中文.wav"), ("ja", "作品/日本語.wav"), ("ko", "작품/한국어.wav")] {
        test("ZIP unflagged UTF8 \(id) retains filename and CP437 iterator identity") {
            let raw = Data(name.utf8), entry = try inspect("unflagged-" + id, [Entry(raw: raw)]).entries[0]
            let cp437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x400)))
            try require(entry.relativePath == name && entry.archivePath == String(data: raw, encoding: cp437) && entry.archivePath != name)
        }
    }
    test("ZIP flagged UTF8 unchanged") {
        let name = "作品/日本語.wav", e = try inspect("flagged", [Entry(raw: Data(name.utf8), flags: 0x0800)]).entries[0]
        try require(e.relativePath == name && e.archivePath == name)
    }
    test("ZIP ASCII unflagged unchanged") { let e = try inspect("ascii", [Entry(raw: Data("a.wav".utf8))]).entries[0]; try require(e.relativePath == "a.wav" && e.archivePath == "a.wav") }
    test("ZIP invalid UTF8 with no flag still falls back to CP437") {
        let raw = Data([0x82]) + Data(".wav".utf8), e = try inspect("cp437", [Entry(raw: raw)]).entries[0]
        try require(e.relativePath == "é.wav" && e.archivePath == "é.wav")
    }
    test("ZIP invalid UTF8 with bit11 rejected") { try reject("bad-flagged", [Entry(raw: Data([0xff]) + Data(".wav".utf8), flags: 0x0800)]) }
    test("ZIP valid Unicode extra overrides unflagged UTF8") {
        let raw = Data("日本語.wav".utf8), e = try inspect("unicode-priority", [Entry(raw: raw, extra: unicodeExtra(raw: raw, path: "中文.wav"))]).entries[0]
        try require(e.relativePath == "中文.wav")
    }
    test("ZIP invalid Unicode extra CRC falls back to UTF8") {
        let raw = Data("日本語.wav".utf8), e = try inspect("unicode-badcrc", [Entry(raw: raw, extra: unicodeExtra(raw: raw, path: "ignored.wav", validCRC: false))]).entries[0]
        try require(e.relativePath == "日本語.wav")
    }
    test("ZIP flagged UTF8 conflicting Unicode extra rejected") {
        let raw = Data("日本語.wav".utf8); try reject("unicode-conflict", [Entry(raw: raw, flags: 0x0800, extra: unicodeExtra(raw: raw, path: "中文.wav"))])
    }
    test("ZIP unflagged UTF8 traversal rejected") { try reject("traversal", [Entry(raw: Data("作品/../escape.wav".utf8))]) }
    test("ZIP Unicode extra traversal rejected") {
        let raw = Data("日本語.wav".utf8); try reject("unicode-traversal", [Entry(raw: raw, extra: unicodeExtra(raw: raw, path: "../escape.wav"))])
    }
    test("ZIP fallback and flagged path collision rejected") { let raw = Data("日本語.wav".utf8); try reject("collision", [Entry(raw: raw), Entry(raw: raw, flags: 0x0800)]) }
    test("ZIP Unicode canonical path collision rejected") { try reject("canonical-collision", [Entry(raw: Data("é.wav".utf8)), Entry(raw: Data("e\u{301}.wav".utf8))]) }
    test("ZIP unflagged UTF8 empty directory accepted") {
        let e = try inspect("directory", [Entry(raw: Data("作品/".utf8), payload: Data())]).entries[0]
        try require(e.isDirectory && e.relativePath == "作品")
    }
}
if !riskMode {
    for fixture in ["unflagged-zh", "unflagged-ja", "unflagged-ko", "unicode-priority"] {
        test("ZIPFoundation actual iterator identity and CRC extraction: \(fixture)") {
            let url = fixtures.appendingPathComponent(fixture + ".zip")
            let manifest = try ZIPArchiveInspector.inspect(at: url)
            let archive = try Archive(url: url, accessMode: .read)
            let entries = Array(archive)
            try require(entries.count == manifest.entries.count)
            for (actual, expected) in zip(entries, manifest.entries) {
                try require(actual.path == expected.archivePath, "iterator identity mismatch")
                var bytes = Data()
                let crc = try archive.extract(actual, skipCRC32: false) { bytes.append($0) }
                try require(crc == expected.crc32 && bytes == Data("fixture".utf8), "content/CRC mismatch")
            }
        }
    }
    test("ZIPFoundation returned CRC detects corrupt payload for app guard") {
        var bytes = zipData([Entry(raw: Data("日本語.wav".utf8))])
        let payloadStart = 30 + Data("日本語.wav".utf8).count
        bytes[payloadStart] ^= 1
        let url = fixtures.appendingPathComponent("corrupt-payload.zip")
        try bytes.write(to: url)
        _ = try ZIPArchiveInspector.inspect(at: url) // structural precheck alone cannot detect changed payload
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive.first(where: { _ in true }) else { throw CheckFailure(message: "missing entry") }
        // extract returns calculated CRC; it does not compare it to the recorded CRC.
        // ZIPArchiveStager.swift:167 explicitly performs this comparison in the app.
        let actualCRC = try archive.extract(entry, skipCRC32: false) { _ in }
        try require(actualCRC != entry.checksum, "corrupt payload was not detectable by returned CRC")
    }
}
if riskMode {
    // Regression guards for previously failing language aliases and separate subtitle folders.
    test("RISK same-language aliases ja+jp should not become bilingual") {
        let p = pair([ja, "/w/01.jp.srt"])
        print("  observed primary=\(p.primary.languageHint ?? "nil") secondary=\(p.secondary?.languageHint ?? "nil")")
        try require(p.secondary == nil, "ja and jp are both Japanese, but treated as distinct languages")
    }
    test("RISK same-language aliases zh+cn should not become bilingual") {
        let p = pair([zh, "/w/01.cn.srt"])
        print("  observed primary=\(p.primary.languageHint ?? "nil") secondary=\(p.secondary?.languageHint ?? "nil")")
        try require(p.secondary == nil, "zh and cn are both Chinese, but treated as distinct languages")
    }
    test("RISK unique audio plus two siblings in subtitle directory should be importable") {
        let audio = "/w/audio/01.wav"
        let paths = ["/w/subs/01.ja.srt", "/w/subs/01.zh.srt"]
        let matches = SubtitleSidecarFinder.importMatches(audioPaths: [audio], subtitlePaths: paths)
        print("  observed matches=\(matches.count), direct importPair secondary=\(pair(paths).secondary?.path ?? "nil")")
        try require(matches[audio] != nil, "cross-directory equal-confidence candidates rejected before importPair")
    }
}
print("SUMMARY cases_passed=\(passed) cases_failed=\(failed) mode=\(riskMode ? "risk-probes" : "regression")")
try? FileManager.default.removeItem(at: fixtures)
exit(failed == 0 ? 0 : 1)
