import Foundation

/// 找到的同名字幕文件
public struct SidecarSubtitleMatch: Equatable, Sendable {
    /// 完整路径
    public var path: String
    public var format: SubtitleFormat
    /// 从文件名推断出的语言（`ja` / `zh` / `en`…），可能为 nil
    public var languageHint: String?
    /// 与音频文件名的相似度（越高越可信），0…1
    public var confidence: Double

    public init(path: String, format: SubtitleFormat, languageHint: String? = nil, confidence: Double = 1.0) {
        self.path = path
        self.format = format
        self.languageHint = languageHint
        self.confidence = confidence
    }
}

/// 在同目录里寻找音频对应的字幕文件。
///
/// 纯函数：只要给它"同目录下所有文件名"就行，方便单元测试。
/// 真实音声作品常见几种命名：
/// ```
/// 01 本編.mp3   → 01 本編.mp3.vtt     （保留音频扩展名）
/// 01 本編.mp3   → 01 本編.srt
/// 01 本編.mp3   → 01 本編.ja.srt      （带语言后缀）
/// 01 本編.mp3   → 01 本編.zh.srt
/// 01 本編.mp3   → 本編.srt            （前缀轨号被省掉）
/// ```
public enum SubtitleSidecarFinder {

    /// 支持的"语言后缀"（出现在字幕扩展名之前）
    static let languageHints: Set<String> = [
        "ja", "jp", "jpn", "zh", "cn", "chs", "cht", "zh-cn", "zh-tw",
        "en", "eng", "ko", "kor", "yue"
    ]

    /// 在候选文件里找出与该音频对应的字幕
    /// - Parameters:
    ///   - audioFileName: 音频文件名（含扩展名）
    ///   - candidatePaths: 同目录下的所有文件完整路径
    /// - Returns: 按可信度降序排列的候选
    public static func find(audioFileName: String, candidatePaths: [String]) -> [SidecarSubtitleMatch] {
        let audioBase = normalizeBase((audioFileName as NSString).deletingPathExtension)
        let audioWithoutNumber = stripLeadingTrackNumber(audioBase)

        var results: [SidecarSubtitleMatch] = []

        for path in candidatePaths {
            let fileName = (path as NSString).lastPathComponent
            let ext = (fileName as NSString).pathExtension.lowercased()
            guard let format = SubtitleFormat.from(fileExtension: ext) else { continue }

            let (base, language) = subtitleName(fileName)
            let normalizedBase = normalizeBase(base)
            let confidence: Double

            if base.lowercased() == audioFileName.lowercased()
                || (!audioBase.isEmpty && normalizedBase == audioBase) {
                confidence = 1.0
            } else if !audioWithoutNumber.isEmpty, normalizedBase == audioWithoutNumber {
                // 字幕省掉了轨号前缀
                confidence = 0.85
            } else if !audioWithoutNumber.isEmpty,
                      normalizedBase.hasSuffix(audioWithoutNumber),
                      normalizedBase.count > audioWithoutNumber.count {
                // 字幕名比音频名长一点（比如多了"【簡体字】"这类前缀）
                confidence = 0.7
            } else {
                continue
            }

            results.append(
                SidecarSubtitleMatch(
                    path: path,
                    format: format,
                    languageHint: language,
                    confidence: confidence
                )
            )
        }

        return results.sorted(by: preferredMatch)
    }

    /// 在作品内规划导入。同目录同曲名的不同编码可共用通用字幕，其余有歧义时不配。
    public static func importMatches(
        audioPaths: [String], subtitlePaths: [String], selectedAudioPaths: Set<String>? = nil
    ) -> [String: SidecarSubtitleMatch] {
        guard !audioPaths.isEmpty, !subtitlePaths.isEmpty else { return [:] }
        func directory(_ path: String) -> String { (path as NSString).deletingLastPathComponent }
        func name(_ path: String) -> String { (path as NSString).lastPathComponent }

        let audioDirs = Dictionary(grouping: Set(audioPaths), by: directory)
        let subDirs = Dictionary(grouping: Set(subtitlePaths).filter {
            SubtitleFormat.from(fileExtension: ($0 as NSString).pathExtension) != nil
        }, by: directory)

        var byName: [String: [String]] = [:]
        var byNumber: [Int: [String]] = [:]
        var localMatches: [String: [(audio: String, match: SidecarSubtitleMatch)]] = [:]
        for (dir, tracks) in audioDirs {
            for audio in tracks {
                let fileName = name(audio)
                for key in Set([fileName, (fileName as NSString).deletingPathExtension]) {
                    byName[key.lowercased(), default: []].append(audio)
                }
                if let number = FolderNameParser.trackNumber(from: fileName) {
                    byNumber[number, default: []].append(audio)
                }
                for match in find(audioFileName: fileName, candidatePaths: subDirs[dir] ?? []) {
                    localMatches[match.path, default: []].append((audio, match))
                }
            }
        }

        // 轨号的唯一性要按整部作品判断，即使某份字幕已经按名字配好。
        let subtitlesByNumber = Dictionary(grouping: subDirs.values.joined()) {
            FolderNameParser.trackNumber(from: name($0))
        }
        var candidates: [String: [SidecarSubtitleMatch]] = [:]
        var reserved: Set<String> = []
        for (dir, paths) in subDirs {
            for path in paths {
                guard let format = SubtitleFormat.from(fileExtension: (path as NSString).pathExtension) else { continue }
                let (base, language) = subtitleName(name(path))
                let exact = byName[base.lowercased()] ?? []
                let localExact = exact.filter { directory($0) == dir }
                let local = localMatches[path] ?? []

                let owners: [String]
                let confidence: Double
                if !exact.isEmpty {
                    let named = localExact.isEmpty ? exact : localExact
                    // 同目录、同曲名的 WAV/MP3 可共用裸曲名字幕。跨 SE 目录仍算不同录音。
                    if named.count > 1, let selectedAudioPaths,
                       Set(named.map(directory)).count == 1,
                       named.allSatisfy({ (name($0) as NSString).deletingPathExtension.lowercased() == base.lowercased()
                           && MediaExtensions.kind(forFileName: $0) == .audio }),
                       Set(named.map { ($0 as NSString).pathExtension.lowercased() }).count == named.count {
                        owners = named.filter(selectedAudioPaths.contains)
                        // 格式专属字幕比这一份共享字幕更精确。
                        confidence = localExact.isEmpty ? 0.95 : 0.96
                    } else {
                        owners = named.count == 1 ? named : []
                        confidence = localExact.isEmpty ? 0.98 : 1
                    }
                } else if let best = local.map({ $0.match.confidence }).max() {
                    let closest = local.filter { $0.match.confidence == best }
                    owners = closest.count == 1 ? closest.map(\.audio) : []
                    confidence = min(best, 0.94)
                } else if let number = FolderNameParser.trackNumber(from: name(path)),
                          let tracks = byNumber[number] {
                    reserved.insert(path)
                    guard tracks.count == 1, subtitlesByNumber[number]?.count == 1 else { continue }
                    // 字幕名中明确标了媒体格式时，不把它挂到另一个格式的录音。
                    let embedded = (base as NSString).pathExtension.lowercased()
                    if MediaExtensions.isLibraryMedia(base),
                       embedded != (tracks[0] as NSString).pathExtension.lowercased() { continue }
                    owners = tracks
                    confidence = 0.6
                } else {
                    continue
                }

                reserved.insert(path)
                for owner in owners {
                    candidates[owner, default: []].append(SidecarSubtitleMatch(
                        path: path, format: format, languageHint: language, confidence: confidence
                    ))
                }
            }
        }

        var result: [String: SidecarSubtitleMatch] = [:]
        for (audio, matches) in candidates {
            let sorted = matches.sorted(by: preferredMatch)
            guard let first = sorted.first else { continue }
            // 跨目录出现两份同样可信的字幕，保留给用户手选。
            if directory(first.path) != directory(audio),
               sorted.dropFirst().first?.confidence == first.confidence { continue }
            result[audio] = first
        }

        // 保留同目录「只剩一首和一份」的旧规则。多语言副本或归属冲突的字幕不可再分配。
        for (dir, tracks) in audioDirs {
            let remaining = tracks.filter { result[$0] == nil }
            let unused = (subDirs[dir] ?? []).filter { !reserved.contains($0) }
            guard remaining.count == 1, unused.count == 1, candidates[remaining[0]] == nil else { continue }
            let path = unused[0]
            let (base, language) = subtitleName(name(path))
            guard !MediaExtensions.isLibraryMedia(base),
                  FolderNameParser.trackNumber(from: name(path)) == nil,
                  let format = SubtitleFormat.from(fileExtension: (path as NSString).pathExtension) else { continue }
            result[remaining[0]] = SidecarSubtitleMatch(path: path, format: format, languageHint: language, confidence: 0.5)
        }
        return result
    }

    private static func subtitleName(_ fileName: String) -> (base: String, language: String?) {
        let base = (fileName as NSString).deletingPathExtension
        let suffix = (base as NSString).pathExtension.lowercased()
        return languageHints.contains(suffix) ? ((base as NSString).deletingPathExtension, suffix) : (base, nil)
    }

    private static func preferredMatch(_ a: SidecarSubtitleMatch, _ b: SidecarSubtitleMatch) -> Bool {
        if a.confidence != b.confidence { return a.confidence > b.confidence }
        if (a.languageHint != nil) != (b.languageHint != nil) { return a.languageHint != nil }
        return NaturalSort.compare(a.path, b.path)
    }

    /// 在两份字幕之间配对"原文"和"译文"
    ///
    /// 常见情况：`作品.ja.srt` + `作品.zh.srt`。
    /// 返回（原文, 译文）的组合；只有一份时译名为 nil。
    public static func pair(
        _ matches: [SidecarSubtitleMatch],
        preferPrimary primary: String? = "ja"
    ) -> [(primary: SidecarSubtitleMatch, secondary: SidecarSubtitleMatch?)] {
        var groups: [String: [SidecarSubtitleMatch]] = [:]
        var order: [String] = []

        for match in matches {
            // 注意顺序：先去掉扩展名和语言后缀（此时还带点），最后才归一化。
            // 反过来的话归一化会把点去掉，"01.ja" 变成 "01ja"，语言后缀就找不到了。
            let fileName = (match.path as NSString).lastPathComponent
            var base = (fileName as NSString).deletingPathExtension
            for language in languageHints where base.lowercased().hasSuffix("." + language) {
                base = String(base.dropLast(language.count + 1))
            }
            let key = normalizeBase(base)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(match)
        }

        var pairs: [(SidecarSubtitleMatch, SidecarSubtitleMatch?)] = []
        for key in order {
            guard let list = groups[key], !list.isEmpty else { continue }
            let sorted = list.sorted { a, b in
                if a.confidence != b.confidence { return a.confidence > b.confidence }
                return NaturalSort.compare(a.path, b.path)
            }

            if sorted.count == 1 {
                pairs.append((sorted[0], nil))
                continue
            }

            // 找首选语言作为原文
            let primaryMatch = sorted.first { $0.languageHint == primary } ?? sorted[0]
            let secondaryMatch = sorted.first {
                $0.path != primaryMatch.path && $0.languageHint != primaryMatch.languageHint
            }
            pairs.append((primaryMatch, secondaryMatch))
        }
        return pairs
    }

    /// Only pair an unambiguous same-directory, same-format language sibling.
    /// Ownership is still decided by importMatches, including audio variant rules.
    public static func importPair(for selected: SidecarSubtitleMatch, subtitlePaths: [String])
        -> (primary: SidecarSubtitleMatch, secondary: SidecarSubtitleMatch?) {
        let selectedURL = URL(fileURLWithPath: selected.path)
        let selectedName = subtitleName(selectedURL.lastPathComponent)
        guard selectedName.language != nil else { return (selected, nil) }
        let siblings = subtitlePaths.compactMap { path -> SidecarSubtitleMatch? in
            let url = URL(fileURLWithPath: path)
            let name = subtitleName(url.lastPathComponent)
            guard url.deletingLastPathComponent() == selectedURL.deletingLastPathComponent(),
                  name.base == selectedName.base, name.language != nil,
                  url.pathExtension.lowercased() == selectedURL.pathExtension.lowercased() else { return nil }
            return SidecarSubtitleMatch(path: path, format: selected.format,
                languageHint: name.language, confidence: selected.confidence)
        }
        guard siblings.count == 2, Set(siblings.compactMap(\.languageHint)).count == 2,
              let pair = pair(siblings).first else { return (selected, nil) }
        return pair
    }

    // MARK: - 内部

    /// 归一化文件名：去掉标点空格、全角转半角、小写
    static func normalizeBase(_ name: String) -> String {
        var result = ""
        for scalar in name.unicodeScalars {
            var value = scalar.value
            // 全角 → 半角
            if value >= 0xFF01 && value <= 0xFF5E { value -= 0xFEE0 }
            if value >= 0x41 && value <= 0x5A { value += 0x20 }   // 大写转小写
            guard let normalized = Unicode.Scalar(value) else { continue }
            let ch = Character(normalized)
            // 只保留字母数字、假名、汉字
            if normalized.isASCII {
                if ch.isLetter || ch.isNumber { result.append(ch) }
            } else if (0x3040...0x30FF).contains(value) || (0x4E00...0x9FFF).contains(value) {
                result.append(ch)
            }
        }
        return result
    }

    /// 去掉开头的轨号（"01"、"tr1"、"第2話" 之类）
    static func stripLeadingTrackNumber(_ base: String) -> String {
        let patterns = [
            "^\\d{1,3}",
            "^tr\\d{1,3}",
            "^track\\d{1,3}",
            "^第\\d{1,3}[話话章]"
        ]
        var result = base
        for pattern in patterns {
            if let range = result.range(of: pattern, options: .regularExpression),
               range.lowerBound == result.startIndex {
                result = String(result[range.upperBound...])
                break
            }
        }
        return result
    }
}
