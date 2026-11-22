import Foundation

/// Saved alongside an independent audio clip, never a live reference to its source.
public struct ClipSubtitleSnapshot: Codable, Equatable, Sendable {
    public let cues: [SubtitleCue]
    public let sourceLabel: String
    public let capturedAt: Date

    public init(cues: [SubtitleCue], sourceLabel: String = "摘选字幕", capturedAt: Date = Date()) {
        self.cues = cues
        self.sourceLabel = sourceLabel
        self.capturedAt = capturedAt
    }
}

public struct ClipSubtitleSegment: Sendable {
    public let cues: [SubtitleCue]
    public let durationMS: Int

    public init(cues: [SubtitleCue], durationMS: Int) {
        self.cues = cues
        self.durationMS = durationMS
    }
}

public enum ClipSubtitleTimeline {
    public enum Error: Swift.Error { case invalidDuration }

    /// Use half-open ranges: a line ending at the clip start or starting at its
    /// end belongs to the neighbouring clip. Untimed text cannot be associated
    /// with an arbitrary audio range and must not acquire invented timestamps.
    public static func crop(_ cues: [SubtitleCue], startMS: Int, endMS: Int) -> [SubtitleCue] {
        guard startMS >= 0, endMS > startMS else { return [] }
        let selected = cues.enumerated().filter {
            $0.element.hasTiming && $0.element.endMS > startMS && $0.element.startMS < endMS
        }.sorted {
            $0.element.startMS == $1.element.startMS ? $0.offset < $1.offset
                : $0.element.startMS < $1.element.startMS
        }
        return selected.enumerated().map { index, item in
            var cue = item.element
            cue.id = UUID()
            cue.index = index
            cue.startMS = max(startMS, cue.startMS) - startMS
            cue.endMS = min(endMS, cue.endMS) - startMS
            return cue
        }
    }

    /// Durations come from the audio merger's actual output-frame boundaries.
    /// Even a segment without subtitles advances the next segment's time axis.
    public static func concatenate(_ segments: [ClipSubtitleSegment]) throws -> [SubtitleCue] {
        var result: [SubtitleCue] = []
        var offset = 0
        for segment in segments {
            guard segment.durationMS > 0 else { throw Error.invalidDuration }
            let next = offset.addingReportingOverflow(segment.durationMS)
            guard !next.overflow else { throw Error.invalidDuration }
            for var cue in crop(segment.cues, startMS: 0, endMS: segment.durationMS) {
                cue.index = result.count
                cue.startMS += offset
                cue.endMS += offset
                result.append(cue)
            }
            offset = next.partialValue
        }
        return result
    }
}
