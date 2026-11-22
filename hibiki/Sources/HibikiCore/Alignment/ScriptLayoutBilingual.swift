import Foundation

/// An additional, bounded source of evidence. Text-only decisions remain the
/// baseline; layout never supplies missing text, changes timing, or trains on
/// its own inferred pairs.
public enum ScriptLayoutBilingual {
    private typealias Feature = ScriptBilingualDecision.Feature
    private struct Style {
        var font: String?
        var size: Double?
        var indentation: Double?
    }
    private struct Cut {
        var original: String
        var translation: String
        var originalFirst: Bool
        var originalStyle: Style
        var translationStyle: Style
        var page: Int
        var pageWidth: Double
        var pageHeight: Double
        var features: [Feature]
    }

    public static func separating(_ lines: [ScriptLine], classifier: BilingualText.Classifier? = nil) -> [ScriptLine] {
        let probe = classifier ?? BilingualText.layoutLanguageEvidence
        let counts = Dictionary(grouping: lines.compactMap(\.printedStartMS), by: { $0 })
        var latest = -1
        let validTimes = lines.map { line -> Bool in
            guard let start = line.printedStartMS, let end = line.printedEndMS,
                  start > latest, end > start, counts[start]?.count == 1 else { return false }
            latest = start
            return true
        }
        func timed(_ index: Int) -> Bool { validTimes[index] }
        // Freeze independently accepted text pairs before making any inference.
        let anchors: [Int: Cut] = Dictionary(uniqueKeysWithValues: lines.indices.compactMap { index in
            guard timed(index), let pair = BilingualText.split(rawText(lines[index]), classifier: classifier),
                  let cut = textCut(lines[index].sourceLines, pair: pair) else { return nil }
            return (index, cut)
        })
        var result = lines
        for index in lines.indices {
            if lines[index].translatedText != nil {
                result[index].bilingualDecision = .init(method: .text)
                continue
            }
            func reject(_ reason: ScriptBilingualDecision.Reason) {
                result[index].bilingualDecision = .init(method: .unresolved, reason: reason)
            }
            guard timed(index) else { reject(.incompleteTiming); continue }
            let source = nonempty(lines[index].sourceLines)
            guard source.count >= 2, source.allSatisfy({ $0.layout?.isUsable == true }) else {
                reject(.missingReliableLayout); continue
            }
            guard Set(source.compactMap { $0.layout?.pageIndex }).count == 1 else { reject(.crossPage); continue }
            guard BilingualText.compatibleSpeakers(source.map(\.text)) else { reject(.uncertainLanguage); continue }
            let cuts = languageCuts(source, probe: probe)
            guard !cuts.isEmpty else { reject(.uncertainLanguage); continue }
            let distinct = cuts.filter { !$0.features.isEmpty }
            guard !distinct.isEmpty else { reject(.indistinguishableRoles); continue }
            var accepted: [(Cut, [Int], [Feature])] = []
            var conflict = false
            for cut in distinct {
                var support: [Int] = []
                var common = Set(cut.features)
                var candidateConflict = false
                for step in [-1, 1] {
                    for distance in 1...4 {
                        let neighbour = index + step * distance
                        guard lines.indices.contains(neighbour) else { break }
                        guard timed(neighbour), let first = nonempty(lines[neighbour].sourceLines).first?.layout,
                              first.isUsable, first.pageIndex == cut.page,
                              abs(first.pageWidth - cut.pageWidth) < 1, abs(first.pageHeight - cut.pageHeight) < 1 else { break }
                        if let anchor = anchors[neighbour] {
                            let features = Set(cut.features.filter { matches(cut, anchor, feature: $0) })
                            if anchor.originalFirst != cut.originalFirst || features.isEmpty {
                                conflict = true
                                candidateConflict = true
                                break // Opposite or changed styles are a barrier, not skipped evidence.
                            }
                            common.formIntersection(features)
                            support.append(neighbour)
                        } else {
                            // A changed role pattern, missing geometry, or uncertain
                            // source block cannot be crossed just to find more anchors.
                            let shapes = languageCuts(nonempty(lines[neighbour].sourceLines), probe: probe)
                            if !shapes.contains(where: { shape in
                                shape.originalFirst == cut.originalFirst
                                    && cut.features.contains(where: { matches(cut, shape, feature: $0) })
                            }) { break }
                        }
                    }
                }
                if !candidateConflict, support.count >= 3, support.contains(where: { $0 < index }), support.contains(where: { $0 > index }), !common.isEmpty {
                    accepted.append((cut, support.sorted(), cut.features.filter { common.contains($0) }))
                }
            }
            guard accepted.count == 1, let selected = accepted.first else {
                reject(accepted.count > 1 ? .ambiguousBoundary : conflict ? .conflictingPattern : .insufficientAnchors)
                continue
            }
            let pair = BilingualText.Pair(original: selected.0.original, translation: selected.0.translation)
            let rendered = ScriptParser.pairedLine(pair, raw: lines[index].rawLine)
            result[index].text = rendered.text
            result[index].translatedText = rendered.translatedText
            result[index].speaker = lines[index].speaker ?? rendered.speaker
            result[index].bilingualDecision = .init(method: .localLayout, anchorIndices: selected.1, features: selected.2)
        }
        return result
    }

    private static func rawText(_ line: ScriptLine) -> String { line.sourceLines.map(\.text).joined(separator: "\n") }
    private static func nonempty(_ lines: [ScriptTextLine]) -> [ScriptTextLine] {
        lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private static func text(_ rows: [ScriptTextLine]) -> String {
        rows.map { BilingualText.withoutLanguageLabel($0.text).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
    private static func textCut(_ rows: [ScriptTextLine], pair: BilingualText.Pair) -> Cut? {
        let candidates = geometricCuts(nonempty(rows)).filter { $0.original == pair.original && $0.translation == pair.translation }
        return candidates.count == 1 ? candidates[0] : nil
    }
    private static func languageCuts(_ rows: [ScriptTextLine], probe: BilingualText.Classifier) -> [Cut] {
        guard !rows.contains(where: { BilingualText.isStandaloneNote($0.text) }) else { return [] }
        return geometricCuts(rows).filter { cut in
            let jp = BilingualText.withoutSpeaker(cut.original)
            let zh = BilingualText.withoutSpeaker(cut.translation)
            guard jp.unicodeScalars.contains(where: isKana), !zh.unicodeScalars.contains(where: isKana),
                  zh.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }),
                  probe(jp) == .japanese, probe(zh) == .chinese else { return false }
            // Several individually ambiguous short Han rows cannot pool their
            // character counts to masquerade as one independently known side.
            guard cut.translation.components(separatedBy: "\n").contains(where: {
                BilingualText.language(of: $0, classifier: probe) == .chinese
            }) else { return false }
            // Layout cannot turn a shared short kanji word into Chinese. Reuse
            // the general orthographic/grammar guard, never a finite denylist.
            let han = zh.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
            return han >= 5 || BilingualText.positiveChineseEvidence(zh)
        }
    }
    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3041...0x3096).contains(scalar.value) || (0x30A1...0x30FA).contains(scalar.value)
    }
    private static func geometricCuts(_ rows: [ScriptTextLine]) -> [Cut] {
        guard rows.count >= 2, rows.allSatisfy({ $0.layout?.isUsable == true }),
              let first = rows.first?.layout,
              rows.allSatisfy({ row in
                  guard let layout = row.layout else { return false }
                  return layout.pageIndex == first.pageIndex && abs(layout.pageWidth - first.pageWidth) < 1
                      && abs(layout.pageHeight - first.pageHeight) < 1
              }) else { return [] }
        var cuts: [Cut] = []
        for boundary in 1..<rows.count {
            let left = Array(rows[..<boundary]), right = Array(rows[boundary...])
            guard let a = style(left), let b = style(right) else { continue }
            for forward in [true, false] {
                let original = forward ? a : b, translation = forward ? b : a
                cuts.append(Cut(original: text(forward ? left : right), translation: text(forward ? right : left),
                    originalFirst: forward, originalStyle: original, translationStyle: translation,
                    page: first.pageIndex, pageWidth: first.pageWidth, pageHeight: first.pageHeight,
                    features: distinctions(original, translation)))
            }
        }
        return cuts
    }
    private static func style(_ rows: [ScriptTextLine]) -> Style? {
        let layouts = rows.compactMap(\.layout)
        guard layouts.count == rows.count, layouts.allSatisfy(\.isUsable) else { return nil }
        func font(_ name: String) -> String {
            let pieces = name.split(separator: "+", maxSplits: 1)
            return pieces.count == 2 && pieces[0].count == 6 && pieces[0].allSatisfy(\.isUppercase) ? String(pieces[1]) : name
        }
        let fonts = layouts.compactMap(\.fontName).filter { !$0.isEmpty }.map(font)
        let names = Set(fonts)
        let sizes = layouts.compactMap(\.fontSize).filter { $0.isFinite && $0 > 0 }.sorted()
        let lefts = layouts.map { $0.left / $0.pageWidth }.sorted()
        let size = sizes.count == layouts.count && sizes.last! - sizes.first! <= 0.5 ? sizes[sizes.count / 2] : nil
        let indentation = lefts.last! - lefts.first! <= 0.008 ? lefts[lefts.count / 2] : nil
        return Style(font: fonts.count == layouts.count && names.count == 1 ? fonts[0] : nil,
                     size: size, indentation: indentation)
    }
    private static func distinctions(_ a: Style, _ b: Style) -> [Feature] {
        var features: [Feature] = []
        if let x = a.font, let y = b.font, x != y { features.append(.fontName) }
        if let x = a.size, let y = b.size, abs(x - y) >= max(1.5, min(x, y) * 0.12) { features.append(.fontSize) }
        if let x = a.indentation, let y = b.indentation, abs(x - y) >= 0.025 { features.append(.indentation) }
        return features
    }
    private static func matches(_ a: Cut, _ b: Cut, feature: Feature) -> Bool {
        guard b.features.contains(feature) else { return false }
        switch feature {
        case .fontName:
            return a.originalStyle.font == b.originalStyle.font && a.translationStyle.font == b.translationStyle.font
        case .fontSize:
            guard let x = a.originalStyle.size, let y = a.translationStyle.size,
                  let u = b.originalStyle.size, let v = b.translationStyle.size else { return false }
            return abs(x - u) <= 0.5 && abs(y - v) <= 0.5
        case .indentation:
            guard let x = a.originalStyle.indentation, let y = a.translationStyle.indentation,
                  let u = b.originalStyle.indentation, let v = b.translationStyle.indentation else { return false }
            let tolerance = min(0.0075, min(abs(x - y), abs(u - v)) / 4)
            return abs(x - u) <= tolerance && abs(y - v) <= tolerance
        }
    }
}
