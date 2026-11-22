import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
private typealias ScriptPDFFont = UIFont
#elseif canImport(AppKit)
import AppKit
private typealias ScriptPDFFont = NSFont
#endif

/// Keep source ranges and layout with the text. Only proven horizontal,
/// single-column pages can supply reliable position evidence; fallback preserves
/// the PDFKit order and explicitly marks every row as unreliable.
enum PDFScriptTextOrder {
    private static let timeline = try! NSRegularExpression(
        pattern: #"(?m)^\s*[0-9]{1,3}:[0-5][0-9](?::[0-5][0-9])?(?:[.,][0-9]{1,3})?\s*(?:-->|->|—>|–>)\s*[0-9]{1,3}:[0-5][0-9](?::[0-5][0-9])?(?:[.,][0-9]{1,3})?\s*$"#)

    static func hasTimeRanges(_ pages: [String]) -> Bool {
        pages.reduce(0) { $0 + timeline.numberOfMatches(in: $1, range: NSRange($1.startIndex..., in: $1)) } >= 2
    }

    static func text(on page: PDFPage, original: String) -> String {
        lines(on: page, original: original, pageIndex: 0).map(\.text).joined(separator: "\n")
    }

    struct PageExtraction {
        let lines: [ScriptTextLine]
        let excludedLines: [ScriptTextLine]
    }

    static func lines(on page: PDFPage, original: String, pageIndex: Int) -> [ScriptTextLine] {
        extract(on: page, original: original, pageIndex: pageIndex).lines
    }

    private struct Fragment {
        let text: String
        let range: NSRange
        let order: Int
        let box: CGRect?
        let fontName: String?
        let fontSize: Double?
        let isHorizontal: Bool
        var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
        var isPunctuation: Bool {
            !isEmpty && text.unicodeScalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0) || CharacterSet.whitespaces.contains($0)
            }
        }
    }

    static func extract(on page: PDFPage, original: String, pageIndex: Int,
                        excludingRanges: [ScriptSourceRange] = []) -> PageExtraction {
        let pageBox = page.bounds(for: .cropBox)
        let validPage = valid(pageBox)
        let ns = original as NSString
        var fragments: [Fragment] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { raw, range, _, _ in
            let text = raw ?? ""
            let selection = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : page.selection(for: range)
            let box = selection.map { $0.bounds(for: page) }.flatMap { valid($0) ? $0 : nil }
            let font = selection.map { consistentFont(in: $0, original: text) } ?? (nil, nil)
            let horizontal = selection.map { $0.selectionsByLine().count == 1 } == true
                && box.map { isHorizontal(range: range, box: $0, page: page, original: ns) } == true
            fragments.append(Fragment(text: text, range: range, order: fragments.count, box: box,
                                      fontName: font.0, fontSize: font.1, isHorizontal: horizontal))
        }
        func makeLine(_ parts: [Fragment], reliable: Bool) -> ScriptTextLine {
            let boxes = parts.compactMap(\.box)
            let union = boxes.dropFirst().reduce(boxes.first ?? .zero) { $0.union($1) }
            let hasBox = !boxes.isEmpty && validPage
            let names = parts.compactMap(\.fontName)
            let sizes = parts.compactMap(\.fontSize)
            let name = names.count == parts.count && Set(names).count == 1 ? names.first : nil
            let size = sizes.count == parts.count && sizes.allSatisfy { abs($0 - sizes[0]) < 0.01 } ? sizes.first : nil
            var text = parts[0].text
            if parts.count > 1 {
                text = text.trimmingCharacters(in: .whitespaces)
                for index in parts.indices.dropFirst() {
                    let previous = parts[index - 1].box!
                    let current = parts[index].box!
                    let gap = current.minX - previous.maxX
                    text += (gap > min(previous.height, current.height) * 0.25 ? " " : "")
                        + parts[index].text.trimmingCharacters(in: .whitespaces)
                }
            }
            return ScriptTextLine(text: text, layout: ScriptLineLayout(
                pageIndex: pageIndex,
                left: hasBox ? Double(union.minX - pageBox.minX) : 0,
                top: hasBox ? Double(pageBox.maxY - union.maxY) : 0,
                width: hasBox ? Double(union.width) : 0,
                height: hasBox ? Double(union.height) : 0,
                pageWidth: validPage ? Double(pageBox.width) : 0,
                pageHeight: validPage ? Double(pageBox.height) : 0,
                fontName: name, fontSize: size, isReliable: reliable && hasBox),
                sourceLineIndex: parts.count == 1 ? parts[0].order : nil,
                sourceRanges: parts.map { ScriptSourceRange(start: $0.range.location, length: $0.range.length) })
        }
        // A small, isolated page number at the bottom centre is page furniture,
        // not a body line. Never remove a numeric reply by its text alone.
        var excluded: [Fragment] = []
        if page.rotation % 360 == 0, validPage {
            let visible = fragments.filter { !$0.isEmpty && $0.box != nil }
            let sizes = visible.compactMap(\.fontSize).sorted()
            let bodySize = sizes.isEmpty ? 0 : sizes[sizes.count / 2]
            for fragment in visible {
                let box = fragment.box!
                let text = fragment.text.trimmingCharacters(in: .whitespaces)
                let top = pageBox.maxY - box.maxY
                let others = visible.filter { $0.order != fragment.order }
                let lastBody = others.map { $0.box!.minY }.min()
                if fragment.isHorizontal, text.range(of: #"^[0-9０-９]{1,4}$"#, options: .regularExpression) != nil,
                   top >= pageBox.height * 0.80,
                   abs(box.midX - pageBox.midX) <= pageBox.width * 0.12,
                   let size = fragment.fontSize, bodySize > 0, size < bodySize * 0.92,
                   let lastBody, lastBody - box.maxY > max(box.height * 2, 12) {
                    excluded.append(fragment)
                }
            }
        }
        let selectedRanges = Set(excludingRanges.map { "\($0.start):\($0.length)" })
        for fragment in fragments where selectedRanges.contains("\(fragment.range.location):\(fragment.range.length)") {
            if !excluded.contains(where: { $0.order == fragment.order }) { excluded.append(fragment) }
        }
        let excludedLines = excluded.map { makeLine([$0], reliable: false) }
        let excludedOrders = Set(excluded.map(\.order))
        let originalFragments = fragments
        fragments.removeAll { excludedOrders.contains($0.order) }
        let fallback = { PageExtraction(lines: fragments.map { makeLine([$0], reliable: false) }, excludedLines: excludedLines) }
        let visible = fragments.filter { !$0.isEmpty }
        guard page.rotation % 360 == 0, validPage, visible.count >= 2,
              visible.allSatisfy({ fragment in
                  guard let box = fragment.box else { return false }
                  return fragment.isHorizontal && pageBox.insetBy(dx: -1, dy: -1).contains(box)
              }) else { return fallback() }
        let heights = visible.compactMap { $0.box?.height }.sorted()
        let height = heights[heights.count / 2]
        guard visible.allSatisfy({ $0.box!.height < height * 1.8 && $0.box!.height > height * 0.5 }) else { return fallback() }
        let sorted = visible.sorted {
            if $0.box!.midY != $1.box!.midY { return $0.box!.midY > $1.box!.midY }
            if $0.box!.minX != $1.box!.minX { return $0.box!.minX < $1.box!.minX }
            return $0.order < $1.order
        }
        var bands: [[Fragment]] = []
        for fragment in sorted {
            if let last = bands.last, abs(last[0].box!.midY - fragment.box!.midY) < height * 0.35 {
                bands[bands.count - 1].append(fragment)
            } else { bands.append([fragment]) }
        }
        bands = bands.map { $0.sorted { $0.box!.minX == $1.box!.minX ? $0.order < $1.order : $0.box!.minX < $1.box!.minX } }
        let starts = bands.map { $0[0].box!.minX }.sorted()
        let left = starts[starts.count / 2]
        guard starts.filter({ abs($0 - left) < height * 4 }).count * 10 >= starts.count * 9 else { return fallback() }
        for band in bands where band.count > 1 {
            // Detached punctuation can be joined. Two substantive runs might
            // instead be parallel columns, even when their gap is small.
            guard band.filter({ !$0.isPunctuation }).count <= 1 else { return fallback() }
            for index in band.indices.dropFirst() {
                let gap = band[index].box!.minX - band[index - 1].box!.maxX
                guard gap >= -height * 0.2, gap < height * 2 else { return fallback() }
            }
        }
        let rowGaps = zip(bands, bands.dropFirst()).map { $0[0].box!.midY - $1[0].box!.midY }.sorted()
        // A uniformly loose line spacing is not a paragraph break. Compare
        // against this page's ordinary row spacing as well as the font height.
        let paragraphGap = max(height * 2, (rowGaps.isEmpty ? height : rowGaps[(rowGaps.count - 1) / 4]) * 1.65)
        var result: [ScriptTextLine] = []
        var previousBand: [Fragment]?
        for band in bands {
            if let previousBand {
                let previous = previousBand.map(\.order).max()!
                let next = band.map(\.order).min()!
                let blanks = previous + 1 < next ? Array(originalFragments[(previous + 1)..<next]).filter(\.isEmpty) : []
                // Preserve original blanks whose neighbours remain adjacent.
                if !blanks.isEmpty && blanks.count == next - previous - 1 {
                    result.append(contentsOf: blanks.map { makeLine([$0], reliable: false) })
                } else if previousBand[0].box!.midY - band[0].box!.midY > paragraphGap {
                    result.append(ScriptTextLine(text: ""))
                }
            } else {
                result.append(contentsOf: fragments.prefix(while: \.isEmpty).map { makeLine([$0], reliable: false) })
            }
            result.append(makeLine(band, reliable: true))
            previousBand = band
        }
        result.append(contentsOf: fragments.reversed().prefix(while: \.isEmpty).reversed().map { makeLine([$0], reliable: false) })
        return PageExtraction(lines: result, excludedLines: excludedLines)
    }

    private static func valid(_ box: CGRect) -> Bool {
        !box.isNull && !box.isInfinite && box.minX.isFinite && box.minY.isFinite
            && box.width.isFinite && box.height.isFinite && box.width > 0 && box.height > 0
    }

    private static func isHorizontal(range: NSRange, box: CGRect, page: PDFPage, original: NSString) -> Bool {
        // An unrotated page can still contain vertical or rotated text runs.
        // selection(for:) uses the page.string UTF-16 indices; characterBounds
        // can use a different glyph order and must not be mixed with them.
        var characters: [NSRange] = []
        original.enumerateSubstrings(in: range, options: .byComposedCharacterSequences) { value, range, _, _ in
            if value?.trimmingCharacters(in: .whitespaces).isEmpty == false { characters.append(range) }
        }
        guard !characters.isEmpty else { return false }
        let boxes = characters.compactMap { range -> CGRect? in
            guard let bounds = page.selection(for: range)?.bounds(for: page), valid(bounds) else { return nil }
            return bounds
        }
        guard boxes.count == characters.count, let first = boxes.first,
              boxes.allSatisfy({ abs($0.midY - first.midY) <= box.height * 0.35 }) else { return false }
        // PDFKit may already concatenate two columns into one string. Inspect
        // internal visual gaps too, instead of trusting that string as one row.
        return zip(boxes, boxes.dropFirst()).allSatisfy {
            $1.minX - $0.maxX <= box.height * 1.25 && $1.minX >= $0.minX - box.height * 0.35
        }
    }

    private static func consistentFont(in selection: PDFSelection, original: String) -> (String?, Double?) {
        guard let attributed = selection.attributedString, attributed.length > 0,
              attributed.string.filter({ !$0.isWhitespace }) == original.filter({ !$0.isWhitespace }) else { return (nil, nil) }
        var names: [String] = []
        var sizes: [Double] = []
        var missing = false
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let text = (attributed.string as NSString).substring(with: range)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard let font = value as? ScriptPDFFont, font.pointSize.isFinite, font.pointSize > 0 else {
                missing = true
                return
            }
            names.append(font.fontName)
            sizes.append(Double(font.pointSize))
        }
        guard !missing, !names.isEmpty else { return (nil, nil) }
        return (Set(names).count == 1 ? names[0] : nil,
                sizes.allSatisfy { abs($0 - sizes[0]) < 0.01 } ? sizes[0] : nil)
    }
}
