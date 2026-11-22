import UIKit
import CoreImage
import ImageIO

/// Reads subtitle state only. No playback, subtitle selection or editing occurs here.
@MainActor
final class SubtitlePictureInPictureRenderer {
    struct CueEvidence: Equatable {
        let id: UUID
        let texts: [String]
        let isCurrent: Bool
        let frame: CGRect
    }

    struct LayoutEvidence: Equatable {
        let texts: [String]
        let fontSize: CGFloat
        let isTruncated: Bool
        let footer: String?
        let size: CGSize
        let cues: [CueEvidence]
        let statusText: String?
        let usesCoverBackground: Bool
    }

    /// These are the actual strings, rectangles and font size passed to drawing.
    private(set) var lastLayout: LayoutEvidence?
    private(set) var backgroundLoadCount = 0

    private enum Position: Equatable {
        case message(String)
        case context(anchor: Int, current: UUID?)
    }

    private struct FrameKey: Equatable {
        let trackID: Int64?
        let expectedTrackID: Int64?
        let revision: UUID?
        let options: SubtitlePictureInPicturePreferences
        let position: Position
        let backgroundRevision: UInt
        let usesBackground: Bool
        let language: String
    }

    private struct BackgroundRequest: Equatable {
        let path: String?
        let trackID: Int64?
        let revision: UInt
    }

    private struct Block {
        let text: String
        let translated: Bool
    }

    private struct MeasuredCue {
        let cue: SubtitleCue
        let isCurrent: Bool
        let blocks: [Block]
        let heights: [CGFloat]
        var height: CGFloat { heights.reduce(0, +) + CGFloat(max(0, blocks.count - 1)) * 6 + 12 }
    }

    private var cachedKey: FrameKey?
    private var cachedFrame: UIImage?
    private var timelineRevision: UUID?
    private var timelineTrackID: Int64?
    private var timelineCueCount = -1
    private var timeline: [SubtitleCue] = []
    private var timelineIndex: [UUID: Int] = [:]
    private var backgroundRequest: BackgroundRequest?
    private var backgroundTask: Task<Void, Never>?
    private var backgroundImage: UIImage?
    private var backgroundRevision: UInt = 0

    /// Called on source/revision changes, never from the frame timer. Clear the previous
    /// image immediately, then decode and blur away from the main actor.
    func setBackground(path: String?, trackID: Int64?, revision: UInt = 0, onChange: (() -> Void)? = nil) {
        let request = BackgroundRequest(path: path, trackID: trackID, revision: revision)
        guard request != backgroundRequest else { return }
        backgroundRequest = request
        backgroundTask?.cancel(); backgroundTask = nil
        backgroundImage = nil
        backgroundRevision &+= 1
        guard let path, trackID != nil else { return }
        backgroundTask = Task { [weak self] in
            let image = await SubtitlePiPBackgroundCache.shared.image(at: path)
            guard let self, !Task.isCancelled, self.backgroundRequest == request else { return }
            self.backgroundImage = image.map { UIImage(cgImage: $0) }
            self.backgroundLoadCount += 1
            self.backgroundRevision &+= 1
            self.backgroundTask = nil
            onChange?()
        }
    }

    func frame(subtitles: SubtitleController, options: SubtitlePictureInPicturePreferences,
               expectedTrackID: Int64? = nil) -> UIImage {
        updateTimeline(subtitles)
        let position: Position
        if let expectedTrackID, subtitles.loadedTrackID != expectedTrackID {
            position = .message(InterfaceLocalization.text("正在读取当前曲目的字幕…"))
        } else {
            position = self.position(in: subtitles)
        }
        let image = backgroundRequest?.trackID == subtitles.loadedTrackID
            && (expectedTrackID == nil || backgroundRequest?.trackID == expectedTrackID)
            ? backgroundImage : nil
        return cachedRender(position, options: options, trackID: subtitles.loadedTrackID,
                            expectedTrackID: expectedTrackID, revision: subtitles.readingRevision, image: image)
    }

    func frameWithoutTrack(options: SubtitlePictureInPicturePreferences) -> UIImage {
        cachedRender(.message(InterfaceLocalization.text("当前曲目没有可显示的字幕")), options: options,
                     trackID: nil, expectedTrackID: nil, revision: nil, image: nil)
    }

    private func cachedRender(_ position: Position, options: SubtitlePictureInPicturePreferences,
                              trackID: Int64?, expectedTrackID: Int64?, revision: UUID?, image: UIImage?) -> UIImage {
        var normalized = options
        normalized.fontSize = options.fontSize.isFinite ? min(38, max(16, options.fontSize)) : 24
        let image = normalized.background == .cover ? image : nil
        let key = FrameKey(trackID: trackID, expectedTrackID: expectedTrackID, revision: revision,
            options: normalized, position: position, backgroundRevision: backgroundRevision, usesBackground: image != nil,
            language: AppLanguageSelection.shared.code)
        if key == cachedKey, let cachedFrame { return cachedFrame }
        let rendered = render(position, options: normalized, image: image)
        cachedKey = key; cachedFrame = rendered
        return rendered
    }

    private func updateTimeline(_ subtitles: SubtitleController) {
        guard timelineRevision != subtitles.readingRevision || timelineTrackID != subtitles.loadedTrackID
                || timelineCueCount != subtitles.cues.count else { return }
        timelineRevision = subtitles.readingRevision
        timelineTrackID = subtitles.loadedTrackID
        timelineCueCount = subtitles.cues.count
        timeline = subtitles.cues.filter(\.hasTiming).sorted {
            if $0.startMS != $1.startMS { return $0.startMS < $1.startMS }
            return $0.index < $1.index
        }
        timelineIndex = Dictionary(timeline.enumerated().map { ($0.element.id, $0.offset) },
                                   uniquingKeysWith: { first, _ in first })
    }

    private func position(in subtitles: SubtitleController) -> Position {
        if subtitles.isLoading { return .message(InterfaceLocalization.text("正在读取字幕…")) }
        if let error = subtitles.loadError, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           error != "没有字幕" { return .message(InterfaceLocalization.text("字幕暂不可用\n请回 App 查看字幕状态")) }
        guard !subtitles.cues.isEmpty else { return .message(InterfaceLocalization.text("当前曲目没有可显示的字幕")) }
        guard !timeline.isEmpty else { return .message(InterfaceLocalization.text("台本未打轴，请在 App 内阅读")) }
        if let current = subtitles.currentCue, let index = timelineIndex[current.id] {
            return .context(anchor: index, current: current.id)
        }
        // In a gap, retain readable context but never mark a past/future cue as current.
        var low = 0, high = timeline.count
        while low < high {
            let middle = (low + high) / 2
            if timeline[middle].startMS <= subtitles.positionMS { low = middle + 1 }
            else { high = middle }
        }
        return .context(anchor: min(low, timeline.count - 1), current: nil)
    }

    private func blocks(for cue: SubtitleCue, mode: SubtitlePictureInPicturePreferences.DisplayMode) -> [Block] {
        func nonblank(_ text: String?) -> String? {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        let source = nonblank(cue.text), translated = nonblank(cue.translatedText)
        switch mode {
        case .original: return [Block(text: source ?? InterfaceLocalization.text("当前字幕没有原文"), translated: false)]
        case .translation: return [Block(text: translated ?? InterfaceLocalization.text("当前字幕没有译文"), translated: true)]
        case .bilingual:
            var result: [Block] = []
            if let source { result.append(Block(text: source, translated: false)) }
            if let translated { result.append(Block(text: translated, translated: true)) }
            return result.isEmpty ? [Block(text: InterfaceLocalization.text("当前字幕没有正文"), translated: false)] : result
        }
    }

    private func measure(_ cue: SubtitleCue, current: UUID?, options: SubtitlePictureInPicturePreferences,
                         width: CGFloat) -> MeasuredCue {
        let pieces = blocks(for: cue, mode: options.mode)
        let active = cue.id == current
        return MeasuredCue(cue: cue, isCurrent: active, blocks: pieces,
            heights: pieces.map { height($0.text, fontSize: CGFloat(options.fontSize), width: width, emphasized: active) })
    }

    private func render(_ position: Position, options: SubtitlePictureInPicturePreferences, image: UIImage?) -> UIImage {
        let size = options.frameSize
        let fontSize = CGFloat(options.fontSize)
        let foreground: UIColor = options.theme == .black ? .white : .black
        let outer: CGFloat = 20, inset: CGFloat = 10, top: CGFloat = 36, bottom: CGFloat = 12, rowGap: CGFloat = 8
        let width = size.width - outer * 2 - inset * 2
        let bodyHeight = size.height - top - bottom
        var selected: [MeasuredCue] = []
        var status: String?
        var message: String?
        var truncated = false
        var footer: String?
        var allocated: [CGFloat]?

        switch position {
        case .message(let text): message = text
        case .context(let anchor, let current):
            if current == nil { status = InterfaceLocalization.text("当前时段没有字幕") }
            let main = measure(timeline[anchor], current: current, options: options, width: width)
            selected = [main]
            if main.height > bodyHeight {
                truncated = true
                footer = InterfaceLocalization.text("… 内容较长，请在 App 内阅读完整字幕")
                let budget = max(1, bodyHeight - 22 - 12 - CGFloat(max(0, main.blocks.count - 1)) * 6)
                if main.heights.count == 1 { allocated = [budget] }
                else {
                    let half = budget / 2
                    if main.heights[0] <= half { allocated = [main.heights[0], budget - main.heights[0]] }
                    else if main.heights[1] <= half { allocated = [budget - main.heights[1], main.heights[1]] }
                    else { allocated = [half, half] }
                }
            } else {
                var available = bodyHeight - main.height
                var previous = anchor - 1, next = anchor + 1
                var canGoBack = previous >= 0, canGoForward = next < timeline.count
                // Add adjacent whole cues only. A long neighbour never causes smaller
                // type or skipping over that cue to display a distant, shorter sentence.
                while canGoBack || canGoForward {
                    if canGoBack {
                        let row = measure(timeline[previous], current: current, options: options, width: width)
                        if row.height + rowGap <= available {
                            selected.insert(row, at: 0); available -= row.height + rowGap
                            previous -= 1; canGoBack = previous >= 0
                        } else { canGoBack = false }
                    }
                    if canGoForward {
                        let row = measure(timeline[next], current: current, options: options, width: width)
                        if row.height + rowGap <= available {
                            selected.append(row); available -= row.height + rowGap
                            next += 1; canGoForward = next < timeline.count
                        } else { canGoForward = false }
                    }
                }
            }
        }

        var evidence: [CueEvidence] = []
        let rowHeights = selected.map { row in
            allocated.map { $0.reduce(0, +) + CGFloat(max(0, row.blocks.count - 1)) * 6 + 12 } ?? row.height
        }
        let used = rowHeights.reduce(0, +) + CGFloat(max(0, selected.count - 1)) * rowGap
        var y = top + max(0, (bodyHeight - (footer == nil ? 0 : 22) - used) / 2)
        for (index, row) in selected.enumerated() {
            evidence.append(CueEvidence(id: row.cue.id, texts: row.blocks.map(\.text), isCurrent: row.isCurrent,
                frame: CGRect(x: outer, y: y, width: size.width - outer * 2, height: rowHeights[index])))
            y += rowHeights[index] + rowGap
        }
        lastLayout = LayoutEvidence(texts: message.map { [$0] } ?? evidence.flatMap(\.texts),
            fontSize: fontSize, isTruncated: truncated, footer: footer, size: size,
            cues: evidence, statusText: status, usesCoverBackground: image != nil)

        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            drawBackground(image, bounds: CGRect(origin: .zero, size: size), theme: options.theme)
            draw(InterfaceLocalization.text("字幕 · ") + options.mode.displayName + (status.map { " · " + $0 } ?? ""),
                 rect: CGRect(x: outer, y: 8, width: size.width - outer * 2, height: 22),
                 fontSize: 16, color: foreground.withAlphaComponent(0.7))
            if let message {
                let measured = min(bodyHeight, height(message, fontSize: fontSize, width: width, emphasized: false))
                draw(message, rect: CGRect(x: outer + inset, y: top + (bodyHeight - measured) / 2,
                                          width: width, height: measured), fontSize: fontSize, color: foreground)
            }
            for (index, row) in selected.enumerated() {
                let frame = evidence[index].frame
                if row.isCurrent {
                    foreground.withAlphaComponent(options.theme == .black ? 0.12 : 0.08).setFill()
                    UIBezierPath(roundedRect: frame, cornerRadius: 12).fill()
                }
                var textY = frame.minY + 6
                let heights = allocated ?? row.heights
                for (pieceIndex, block) in row.blocks.enumerated() {
                    let opacity: CGFloat = row.isCurrent ? (block.translated ? 0.9 : 1) : (block.translated ? 0.55 : 0.65)
                    draw(block.text, rect: CGRect(x: frame.minX + inset, y: textY, width: width, height: heights[pieceIndex]),
                         fontSize: fontSize, color: foreground.withAlphaComponent(opacity), emphasized: row.isCurrent,
                         truncates: row.heights[pieceIndex] > heights[pieceIndex])
                    textY += heights[pieceIndex] + 6
                }
            }
            if let footer {
                draw(footer, rect: CGRect(x: outer, y: size.height - bottom - 20,
                                          width: size.width - outer * 2, height: 20),
                     fontSize: 14, color: foreground.withAlphaComponent(0.75))
            }
        }
    }

    private func drawBackground(_ image: UIImage?, bounds: CGRect, theme: SubtitlePictureInPicturePreferences.Theme) {
        let base: UIColor = theme == .black ? .black : .white
        base.setFill(); UIRectFill(bounds)
        guard let image else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height))
        // UIRectFill uses copy blending; a translucent fill would replace the artwork.
        // Composite the readability tint over the already drawn image instead.
        base.withAlphaComponent(theme == .black ? 0.56 : 0.82).setFill()
        UIRectFillUsingBlendMode(bounds, .normal)
    }

    private func attributes(fontSize: CGFloat, color: UIColor, emphasized: Bool) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center; paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = max(2, fontSize * 0.12)
        return [.font: UIFont.systemFont(ofSize: fontSize, weight: emphasized ? .semibold : .regular),
                .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private func height(_ text: String, fontSize: CGFloat, width: CGFloat, emphasized: Bool) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: attributes(fontSize: fontSize, color: .black, emphasized: emphasized))
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
    }

    private func draw(_ text: String, rect: CGRect, fontSize: CGFloat, color: UIColor,
                      emphasized: Bool = false, truncates: Bool = false) {
        let attributed = NSAttributedString(string: text, attributes: attributes(fontSize: fontSize, color: color, emphasized: emphasized))
        var options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        if truncates { options.insert(.truncatesLastVisibleLine) }
        let context = UIGraphicsGetCurrentContext()
        context?.saveGState(); context?.clip(to: rect)
        defer { context?.restoreGState() }
        attributed.draw(with: rect, options: options, context: nil)
    }
}

/// ImageIO decoding and Core Image blur run on this actor, not on the frame timer.
private actor SubtitlePiPBackgroundCache {
    static let shared = SubtitlePiPBackgroundCache()
    private struct Key: Hashable { let path: String; let bytes: Int; let modified: Date? }
    private var images: [Key: CGImage] = [:]
    private var order: [Key] = []
    private let context = CIContext(options: [.cacheIntermediates: false])

    func image(at path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let bytes = values.fileSize else { return nil }
        let key = Key(path: path, bytes: bytes, modified: values.contentModificationDate)
        if let cached = images[key] { return cached }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 256]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let input = CIImage(cgImage: thumbnail)
        let blur = input.clampedToExtent().applyingGaussianBlur(sigma: CGFloat(max(thumbnail.width, thumbnail.height)) * 0.08)
        guard let image = context.createCGImage(blur, from: input.extent) else { return nil }
        images[key] = image; order.append(key)
        if order.count > 3 { images.removeValue(forKey: order.removeFirst()) }
        return image
    }
}
