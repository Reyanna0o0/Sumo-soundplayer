import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// A boundary detector, not a translator: uncertain text stays intact.
/// Physical wrapping may differ between languages; only a unique language-block
/// boundary is accepted. Time blocks are never matched to their neighbours.
public enum BilingualText {
    public enum Language { case japanese, chinese }
    public typealias Classifier = (String) -> Language?

    public struct Pair: Equatable {
        public let original: String
        public let translation: String
    }

    /// An optional classifier makes the boundary rules independently testable.
    /// Without the platform language model, explicit labels still work.
    public static func split(_ text: String, classifier: Classifier? = nil) -> Pair? {
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let explicit = labelled(raw)
        if explicit.found { return explicit.pairs?.count == 1 ? explicit.pairs?[0] : nil }
        guard !raw.components(separatedBy: "\n").contains(where: { TimelineLine.parse($0) != nil }) else { return nil }

        // Tabs and spaced column separators are layout evidence, not punctuation
        // or a change from kana to kanji inside an otherwise ordinary sentence.
        let columns = raw.replacingOccurrences(of: #"\t+|[ 　]+[|｜/][ 　]+"#,
                                               with: "\n", options: .regularExpression)
        let lines = columns.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 2, compatibleSpeakers(lines), !lines.contains(where: isStandaloneNote) else { return nil }
        let classify = classifier ?? { systemLanguage($0, relaxed: false) }
        let languages = lines.map { language(of: $0, classifier: classify) }
        // A han-only line is not, by itself, evidence of Chinese.
        guard languages.contains(where: { $0 == .japanese }),
              languages.contains(where: { $0 == .chinese }) else { return nil }
        var candidates: [Pair] = []
        for boundary in 1..<lines.count {
            let left = Array(lines[..<boundary]), right = Array(lines[boundary...])
            let leftKnown = languages[..<boundary].compactMap { $0 }
            let rightKnown = languages[boundary...].compactMap { $0 }
            guard let a = leftKnown.first, let b = rightKnown.first, a != b,
                  leftKnown.allSatisfy({ $0 == a }), rightKnown.allSatisfy({ $0 == b }),
                  language(of: left.joined(separator: "\n"), classifier: classify) == a,
                  language(of: right.joined(separator: "\n"), classifier: classify) == b else { continue }
            let first = left.joined(separator: "\n"), second = right.joined(separator: "\n")
            candidates.append(Pair(original: a == .japanese ? first : second,
                                   translation: a == .japanese ? second : first))
        }
        // Unknown material on the boundary can make several cuts plausible.
        // Preserve that whole block instead of moving a short line to one side.
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Retains IDs, timings, source order, and already-entered translations.
    public static func separating(_ cues: [SubtitleCue], classifier: Classifier? = nil) -> [SubtitleCue] {
        var pairs = cues.map { cue -> Pair? in
            guard cue.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return nil }
            return split(cue.text, classifier: classifier)
        }
        // Repeated layout is supporting evidence, never a way to guess that an
        // arbitrary second kanji line must be Chinese. Only relax a model margin
        // between nearby confirmed pairs with a consistent document direction.
        func direction(_ pair: Pair, in text: String) -> Bool? {
            guard let a = text.range(of: pair.original), let b = text.range(of: pair.translation) else { return nil }
            return a.lowerBound < b.lowerBound
        }
        let anchors = cues.indices.compactMap { index -> (Int, Bool)? in
            guard let pair = pairs[index], let order = direction(pair, in: cues[index].text) else { return nil }
            return (index, order)
        }
        if classifier == nil, anchors.count >= 4 {
            let forward = anchors.filter { $0.1 }.count
            let order = forward * 2 >= anchors.count
            let agreement = order ? forward : anchors.count - forward
            if Double(agreement) / Double(anchors.count) >= 0.90 {
                for index in cues.indices where pairs[index] == nil && cues[index].translatedText == nil {
                    let left = anchors.last { $0.0 < index && $0.1 == order }
                    let right = anchors.first { $0.0 > index && $0.1 == order }
                    guard let left, let right, index - left.0 <= 5, right.0 - index <= 5,
                          let candidate = split(cues[index].text, classifier: { systemLanguage($0, relaxed: true) }),
                          direction(candidate, in: cues[index].text) == order else { continue }
                    pairs[index] = candidate
                }
            }
        }
        return cues.enumerated().map { index, cue in
            guard cue.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                  let pair = pairs[index] else { return cue }
            var result = cue
            result.text = pair.original
            result.translatedText = pair.translation
            return result
        }
    }

    static func language(of raw: String, classifier: Classifier) -> Language? {
        let text = withoutSpeaker(raw).folding(options: .widthInsensitive, locale: nil)
        let scalars = text.unicodeScalars
        let kana = scalars.filter {
            (0x3041...0x3096).contains($0.value) || (0x30A1...0x30FA).contains($0.value)
        }.count
        let han = scalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
        let detected = classifier(text)
        if kana > 0 {
            // A Chinese sentence quoting a Japanese word is not a Japanese block.
            guard detected != .chinese, detected == .japanese || kana >= 2
                    || Double(kana) / Double(max(1, kana + han)) >= 0.4 else { return nil }
            return .japanese
        }
        guard han > 0, detected == .chinese else { return nil }
        if han >= 5 { return .chinese }
        // Short shared-kanji words (先生, 了解, 大丈夫, etc.) remain unknown
        // even when a language model assigns them a high Chinese score.
        // Short Chinese needs positive orthographic/grammatical evidence too.
        return positiveChineseEvidence(text) ? .chinese : nil
    }

    static func positiveChineseEvidence(_ text: String) -> Bool {
        // Forms unlike normal Japanese orthography, Chinese pronouns and
        // particles. These are script/grammar cues, not a list of sample lines.
        let forms = Set("这這们們吗嗎你妳您咱啥呗谢听说没让给对觉爱欢边该还为过从气开关网书声样经时嗯啊哦呀哎喂嗨欸诶唉啦哇")
        let characters = text.filter { $0.isLetter }
        let particles = Set("了呢吧吗嗎呀啊哦")
        return characters.contains(where: { forms.contains($0) })
            || (characters.count >= 3 && characters.contains("我")
                && characters.contains(where: { Set("是的也在就不都很想要能会會").contains($0) }))
            || (characters.count >= 3 && characters.last.map { particles.contains($0) } == true)
    }

    private static func systemLanguage(_ text: String, relaxed: Bool) -> Language? {
        #if canImport(NaturalLanguage)
        // Use a fresh recognizer: accumulated text and cross-thread reuse would
        // make one block's classification depend on unrelated preceding work.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let scores = recognizer.languageHypotheses(withMaximum: 5)
        let japanese = scores[.japanese] ?? 0
        let chinese = (scores[.simplifiedChinese] ?? 0) + (scores[.traditionalChinese] ?? 0)
        if chinese >= 0.95, japanese <= 0.05 { return .chinese }
        if positiveChineseEvidence(text), chinese >= (relaxed ? 0.80 : 0.90), japanese <= (relaxed ? 0.20 : 0.10) { return .chinese }
        if japanese >= 0.90, chinese <= 0.10 { return .japanese }
        #endif
        return nil
    }

    private enum Role { case original, translation }
    private static let labelPattern = try! NSRegularExpression(
        pattern: #"(?i)(?<!\S)(?:\[|【)?(原文|日文|日语|日語|日本語|英文|英語|original|japanese|english|ja|jp|en|译文|譯文|中文|中译|中譯|翻译|翻譯|translation|chinese|zh|cn)(?:\]|】)?\s*[:：]"#
    )
    /// Explicit repeated original/translation pairs can delimit ordinary scripts
    /// even when the translator did not insert blank lines between utterances.
    public static func labelledPairs(_ text: String) -> [Pair]? { labelled(text).pairs }

    /// A separate bracketed instruction has no provable dialogue/translation
    /// role. Explicit language labels above still take precedence.
    static func isStandaloneNote(_ text: String) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return [("（", "）"), ("(", ")"), ("[", "]"), ("［", "］")].contains {
            body.hasPrefix($0.0) && body.hasSuffix($0.1)
        }
    }

    static func withoutLanguageLabel(_ text: String) -> String {
        let ns = text as NSString
        guard let match = labelPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.range.location == 0 else { return text }
        return ns.substring(from: NSMaxRange(match.range))
    }

    /// Layout-assisted inference still requires independently strong model
    /// evidence. Callers also enforce the plain-text short-Han safeguards.
    static func layoutLanguageEvidence(_ text: String) -> Language? {
        #if canImport(NaturalLanguage)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let scores = recognizer.languageHypotheses(withMaximum: 5)
        let ja = scores[.japanese] ?? 0
        let zh = (scores[.simplifiedChinese] ?? 0) + (scores[.traditionalChinese] ?? 0)
        if zh >= 0.98, ja <= 0.02 { return .chinese }
        if ja >= 0.90, zh <= 0.10 { return .japanese }
        #endif
        return nil
    }

    private static func labelled(_ text: String) -> (found: Bool, pairs: [Pair]?) {
        let ns = text as NSString
        let matches = labelPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let first = matches.first else { return (false, nil) }
        guard ns.substring(to: first.range.location).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (true, nil) }
        let originals: Set<String> = ["原文", "日文", "日语", "日語", "日本語", "英文", "英語", "original", "japanese", "english", "ja", "jp", "en"]
        var groups: [(role: Role, text: String)] = []
        for (index, match) in matches.enumerated() {
            let role: Role = originals.contains(ns.substring(with: match.range(at: 1)).lowercased()) ? .original : .translation
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if groups.last?.role == role {
                groups[groups.count - 1].text += "\n" + body
            } else {
                groups.append((role, body))
            }
        }
        guard groups.count >= 2, groups.count.isMultiple(of: 2),
              groups.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return (true, nil) }
        var pairs: [Pair] = []
        for index in stride(from: 0, to: groups.count, by: 2) {
            let pair = Array(groups[index...index + 1])
            guard compatibleSpeakers(pair.flatMap { $0.text.components(separatedBy: "\n") }) else { return (true, nil) }
            pairs.append(Pair(original: pair.first(where: { $0.role == .original })!.text,
                              translation: pair.first(where: { $0.role == .translation })!.text))
        }
        return (true, pairs)
    }

    private static func speaker(_ text: String) -> String? {
        guard let range = text.range(of: #"^(?:【[^】]{1,12}】|[^\s:：「」『』（()）]{1,12}[:：])"#, options: .regularExpression) else { return nil }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "【】:："))
    }
    static func compatibleSpeakers(_ lines: [String]) -> Bool {
        Set(lines.compactMap(speaker)).count <= 1
    }
    static func withoutSpeaker(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            guard speaker(line) != nil, let range = line.range(of: #"^(?:【[^】]{1,12}】|[^\s:：「」『』（()）]{1,12}[:：])"#, options: .regularExpression) else { return line }
            return String(line[range.upperBound...])
        }.joined(separator: "\n")
    }
}
