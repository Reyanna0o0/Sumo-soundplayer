import Foundation

/// 在目录候选内进一步比对 PDF 的标题、章节和录音。不从音频推测时间。
public struct WorkScriptMatching: Sendable {
    public let sections: [ScriptSection]
    public let tracks: [TrackRecord]

    /// 有明确分轨时，封面和角色表等章前文字可保留在原文件里，
    /// 不应占用第一条音轨。没有轨号的台本保留整份正文供手选分界。
    public var assignableSections: [ScriptSection] { OrderedScriptMapping.bodySections(sections) }

    public var suggestedAssignments: [ScriptImportAssignment] {
        ScriptImportPlan.make(sections: assignableSections, tracks: tracks)
    }

    public init(text: String, fileName: String, candidates: [TrackRecord]) {
        self.init(document: ScriptDocument(text: text), fileName: fileName, candidates: candidates)
    }

    public init(document: ScriptDocument, fileName: String, candidates: [TrackRecord]) {
        let name = (fileName as NSString).lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        let type = TrackCategorizer.classify(relativePath: name)
        let parsed = ScriptSectioner.split(document)
        if type == .voiceMessage, !parsed.contains(where: { $0.trackNumber != nil }),
           let numbered = Self.voiceChapters(document) {
            let group = Self.voiceRecordings(for: numbered, candidates: candidates)
            sections = group.isEmpty ? parsed : numbered
            tracks = group
            return
        }
        sections = parsed
        if type == .bonus, parsed.count == 1, parsed[0].trackNumber == nil {
            let tagged = candidates.filter { Self.matchesBonusTitle(name, track: $0) }
            if !tagged.isEmpty {
                // 同标识仍可能有多段故事，交给 ScriptImportPlan 核对是否确为一条录音。
                tracks = tagged
                return
            }
        }
        if parsed.count == 1, parsed[0].trackNumber == nil {
            // 单曲台本常只把曲名或 Track 号写在文件名里。优先逐字核对曲名；
            // 相同编号的几个不同录音仍交给 ScriptImportPlan 拒绝猜测。
            let title = Self.recordingStem(name, isScript: true)
            let named = candidates.filter { !title.isEmpty && Self.recordingStem($0.fileName, isScript: false) == title }
            if !named.isEmpty {
                tracks = named
                return
            }
            if let number = Self.singleTrackNumber(in: name) {
                tracks = candidates.filter { ScriptSectioner.trackNumber(fromFileName: $0.fileName) == number }
                return
            }
        }
        tracks = candidates
    }

    static func recordingStem(_ fileName: String, isScript: Bool) -> String {
        let stem = (fileName as NSString).deletingPathExtension
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
        guard isScript else { return stem.trimmingCharacters(in: .whitespacesAndNewlines) }
        let suffix = #"(?i)[\s._\-]*(?:(?:簡体中文|简体中文|繁体中文|繁體中文|簡体字?|简体字?|繁体字?|繁體字?|中文|日本語|英文)[\s._\-]*)?(?:台本|脚本|劇本|剧本|script)$"#
        return stem.replacingOccurrences(of: suffix, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func singleTrackNumber(in fileName: String) -> Int? {
        let title = recordingStem(fileName, isScript: true)
        // 不把 Track 1–5、Track1 & Track2 或 01–03 当成某一首的单曲台本。
        let number = #"(?:track|tr|トラック)?\s*\.?\s*[0-9]{1,3}"#
        let range = #"^"# + number + #"\s*(?:[-–—~～〜、,+&/至到]|and)\s*"# + number
        guard title.range(of: range, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        if let marker = ScriptSectioner.parseMarker(title) { return marker.number }
        // 「02 简体字台本」表示第 2 首；案卷号、页数、只有数字开头的书名都不推断轨号。
        if title.range(of: #"^[0-9]{1,3}$"#, options: .regularExpression) != nil { return Int(title) }
        return nil
    }

    private static func matchesBonusTitle(_ name: String, track: TrackRecord) -> Bool {
        let audio = track.fileName.precomposedStringWithCanonicalMapping.lowercased()
        guard audio.hasPrefix("【"), let end = audio.firstIndex(of: "】") else { return false }
        let tag = String(audio[audio.index(after: audio.startIndex)..<end])
        guard tag.count > 2, tag.contains("特典") else { return false }
        let stem = (name as NSString).deletingPathExtension
        let stripped = stem.replacingOccurrences(of: #"[_\s.\-]*(?:(?:簡体字?|简体字?|繁体字?|簡體字?|繁體字?|中文|日本語)[_\s.\-]*)?(?:台本|脚本|劇本|剧本)$"#,
                                                 with: "", options: .regularExpression)
        return stripped == tag || stripped == "【\(tag)】"
    }

    private static func voiceChapters(_ document: ScriptDocument) -> [ScriptSection]? {
        // 语音消息台本有时只印「１」「２」。整本必须从 1 连续编号，每段有正文，
        // 且只有一组录音的编号完全吻合。其它普通 PDF 的裸数字仍按页码处理。
        var headings: [Int] = []
        let marked = document.lines.map { line in
            let value = line.text.trimmingCharacters(in: .whitespaces).folding(options: .widthInsensitive, locale: nil)
            guard value.range(of: #"^[0-9]{1,3}$"#, options: .regularExpression) != nil,
                  let number = Int(value) else { return line }
            headings.append(number)
            var heading = line
            heading.text = "TRACK \(number)"
            return heading
        }
        guard headings.count >= 2, headings == Array(1...headings.count) else { return nil }
        let chapters = ScriptSectioner.split(ScriptDocument(lines: marked)).filter { $0.trackNumber != nil }
        guard chapters.count == headings.count else { return nil }
        return chapters
    }

    private static func voiceRecordings(for chapters: [ScriptSection], candidates: [TrackRecord]) -> [TrackRecord] {
        let expected = Set(chapters.compactMap(\.trackNumber))
        let numbered = candidates.filter { ScriptSectioner.trackNumber(fromFileName: $0.fileName) != nil }
        let groups = Dictionary(grouping: numbered) { track in
            let url = URL(fileURLWithPath: track.resolvedFilePath ?? track.filePath)
            var parent = url.deletingLastPathComponent()
            if parent.lastPathComponent.lowercased() == url.pathExtension.lowercased() { parent.deleteLastPathComponent() }
            return parent.standardizedFileURL.path
        }
        let matching = groups.values.filter { group in
            Set(group.compactMap { ScriptSectioner.trackNumber(fromFileName: $0.fileName) }) == expected
        }
        guard matching.count == 1, let group = matching.first,
              ScriptImportPlan.make(sections: chapters, tracks: group).allSatisfy({ $0.trackID != nil }) else { return [] }
        return group
    }
}
