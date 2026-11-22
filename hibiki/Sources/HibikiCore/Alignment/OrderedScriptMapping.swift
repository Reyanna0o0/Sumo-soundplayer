import Foundation

/// 手工选曲后按台本的先后次序分段。没有分轨标题时，由用户指定后续各轨的第一句。
public struct OrderedScriptMapping: Sendable {
    public let sections: [ScriptSection]
    public let lines: [ScriptLine]

    public init(sections: [ScriptSection]) {
        self.sections = Self.bodySections(sections)
        lines = self.sections.flatMap(\.lines)
    }

    static func bodySections(_ sections: [ScriptSection]) -> [ScriptSection] {
        let numbered = sections.filter { $0.trackNumber != nil }
        return numbered.isEmpty ? sections : numbered
    }

    public func usesHeadings(for trackCount: Int) -> Bool {
        sections.count == trackCount && sections.allSatisfy { $0.trackNumber != nil }
    }

    public func assignments(trackIDs: [Int64], starts: [Int64: Int]) -> [ScriptImportAssignment]? {
        guard !trackIDs.isEmpty, !lines.isEmpty, Set(trackIDs).count == trackIDs.count else { return nil }
        if usesHeadings(for: trackIDs.count) {
            return zip(sections, trackIDs).enumerated().map { index, pair in
                ScriptImportAssignment(id: index, section: pair.0, trackID: pair.1, explanation: InterfaceLocalization.text("按点选顺序配对"))
            }
        }
        let boundaries = [0] + trackIDs.dropFirst().compactMap { starts[$0] } + [lines.count]
        guard boundaries.count == trackIDs.count + 1,
              zip(boundaries, boundaries.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        var originalChapters: [Range<Int>: ScriptSection] = [:]
        var offset = 0
        for section in sections {
            let end = offset + section.lines.count
            originalChapters[offset..<end] = section
            offset = end
        }
        return trackIDs.enumerated().map { index, id in
            let range = boundaries[index]..<boundaries[index + 1]
            if let original = originalChapters[range] {
                return ScriptImportAssignment(id: index, section: original, trackID: id, explanation: InterfaceLocalization.text("按原章节配对"))
            }
            // 改了整章边界后，原章的零点与目标音频的零点关系未知。
            // 保留印刷时间供人参考，不让不同录音的局部时间驱动播放或剪辑。
            let body = lines[range].enumerated().map { offset, original -> ScriptLine in
                var line = original
                line.index = offset
                if let stamp = original.printedStartMS {
                    let time = original.printedEndMS.map {
                        "\(SubtitleTime.clockWithMilliseconds(stamp)) --> \(SubtitleTime.clockWithMilliseconds($0))"
                    } ?? (stamp.isMultiple(of: 1000) ? SubtitleTime.clock(stamp) : SubtitleTime.clockWithMilliseconds(stamp))
                    line.text = "[\(time)] " + line.text
                    line.printedStartMS = nil
                    line.printedEndMS = nil
                }
                return line
            }
            let section = ScriptSection(index: index, title: "第 \(range.lowerBound + 1)–\(range.upperBound) 行",
                                        lines: body)
            return ScriptImportAssignment(id: index, section: section, trackID: id, explanation: InterfaceLocalization.text("按指定行配对"))
        }
    }
}
