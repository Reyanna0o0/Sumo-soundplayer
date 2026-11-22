import Foundation

/// 每个音频版本有独立的预览行。手改目标后行号仍稳定。
public struct ScriptImportAssignment: Identifiable, Equatable, Sendable {
    public let id: Int
    public var section: ScriptSection
    public var trackID: Int64?
    public var explanation: String
}

public enum ScriptImportPlan {
    public static func make(sections: [ScriptSection], tracks: [TrackRecord]) -> [ScriptImportAssignment] {
        let numberedTracks = Dictionary(grouping: tracks) { ScriptSectioner.trackNumber(fromFileName: $0.fileName) }
        let numberedSections = Dictionary(grouping: sections.compactMap(\.trackNumber), by: { $0 })
        var rows: [ScriptImportAssignment] = []

        for section in sections {
            let matches: [TrackRecord]
            let reason: String
            if let number = section.trackNumber {
                let candidates = numberedTracks[number] ?? []
                if numberedSections[number]?.count == 1, sameRecording(candidates) {
                    matches = candidates
                    reason = InterfaceLocalization.text("已按轨道号 \(number) 匹配")
                } else {
                    matches = []
                    reason = candidates.isEmpty ? InterfaceLocalization.text("没有找到同轨道号的音频，请选择曲目") : InterfaceLocalization.text("存在重复轨道号，请选择对应曲目")
                }
            } else if sections.count == 1, sameRecording(tracks) {
                matches = tracks
                reason = InterfaceLocalization.text("整份台本对应唯一录音")
            } else {
                matches = []
                reason = InterfaceLocalization.text("没有轨道标记，请选择曲目")
            }

            if matches.isEmpty {
                rows.append(ScriptImportAssignment(id: rows.count, section: section, trackID: nil, explanation: reason))
            } else {
                for track in matches {
                    rows.append(ScriptImportAssignment(id: rows.count, section: section, trackID: track.id,
                        explanation: matches.count == 1 ? reason : "\(reason) · \(track.fileType.uppercased())"))
                }
            }
        }
        return rows
    }

    /// 同名且同目录的编码副本可共享台词。只忽略与文件扩展名相同的末级目录（如 mp3/）。
    /// 其他目录名（有无音效、不同光盘、特典等）必须相同。
    private static func sameRecording(_ tracks: [TrackRecord]) -> Bool {
        guard tracks.count > 1 else { return tracks.count == 1 }
        let formats = Set(tracks.map { $0.fileType.lowercased() })
        guard formats.count == tracks.count else { return false }
        let stems = Set(tracks.map { track in
            let url = URL(fileURLWithPath: track.filePath)
            var parent = url.deletingLastPathComponent()
            if parent.lastPathComponent.lowercased() == url.pathExtension.lowercased() {
                parent.deleteLastPathComponent()
            }
            return parent.appendingPathComponent(url.deletingPathExtension().lastPathComponent).path
        })
        return stems.count == 1
    }

    /// 台本只有起点，显示区间是供人校正的初稿。超出录音或逆序的印刷时间仍供手动查阅。
    public static func cues(for section: ScriptSection, durationMS: Int? = nil) -> [SubtitleCue] {
        let duration = durationMS.flatMap { $0 > 0 ? $0 : nil } ?? Int.max
        let frequencies = Dictionary(grouping: section.lines.compactMap(\.printedStartMS), by: { $0 })
        var latest = -1
        let starts = section.lines.map { line -> Int? in
            guard let stamp = line.printedStartMS, frequencies[stamp]?.count == 1,
                  stamp > latest, stamp < duration else { return nil }
            if let end = line.printedEndMS, end <= stamp || end > duration { return nil }
            latest = stamp
            return stamp
        }
        var next = duration
        var cues = untimedCues(for: section)
        for index in cues.indices.reversed() {
            if let start = starts[index], let end = section.lines[index].printedEndMS {
                cues[index].startMS = start
                cues[index].endMS = end
                cues[index].status = .ok
                next = start
            } else if let start = starts[index],
               let end = CueEditor.automaticEndMS(startMS: start, nextStartMS: next, durationMS: durationMS) {
                cues[index].startMS = start
                cues[index].endMS = end
                cues[index].status = .provisional
                next = start
            } else if let printed = section.lines[index].printedStartMS {
                let reference = section.lines[index].printedEndMS.map {
                    "\(SubtitleTime.clockWithMilliseconds(printed)) --> \(SubtitleTime.clockWithMilliseconds($0))"
                } ?? SubtitleTime.clock(printed)
                cues[index].text = "[\(reference)] " + cues[index].text
            }
        }
        return cues
    }

    public static func untimedCues(for section: ScriptSection) -> [SubtitleCue] {
        section.lines.enumerated().map { index, line in
            SubtitleCue(index: index, startMS: 0, endMS: 0, text: line.text,
                        translatedText: line.translatedText, speaker: line.speaker, status: .untimed)
        }
    }
}
