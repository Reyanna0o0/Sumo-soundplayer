import Foundation

/// 把"译文"合并到"原文"字幕上。
///
/// 现实里原文和译文常是两个文件（`01.ja.srt` + `01.zh.srt`），
/// 条数通常一致但时间轴常有几毫秒偏差，偶尔条数也不同。
public enum SubtitleTranslationMerger {

    /// 合并策略：
    /// 1. 条数相同 → 按序号一一对应（最快最准）
    /// 2. 条数不同 → 按时间重叠匹配，匹配不到就不加译文
    public static func merge(primary: [SubtitleCue], secondary: [SubtitleCue]) -> [SubtitleCue] {
        guard !primary.isEmpty else { return [] }
        guard !secondary.isEmpty else { return primary }

        var result = primary

        if primary.count == secondary.count {
            for index in result.indices {
                let translation = secondary[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !translation.isEmpty {
                    result[index].translatedText = translation
                }
            }
            return result
        }

        // 条数不同：一对一匹配，避免同一句译文被贴到多句原文上
        let sortedSecondary = secondary.sorted { $0.startMS < $1.startMS }
        var primaryTaken = Set<Int>()
        var secondaryTaken = Set<Int>()

        // ① 先按重叠时长从大到小贪心分配（重叠越长越可信）
        struct Pair { let p: Int; let s: Int; let overlap: Int }
        var pairs: [Pair] = []
        for (pi, cue) in primary.enumerated() {
            for (si, cand) in sortedSecondary.enumerated() {
                let overlap = min(cue.endMS, cand.endMS) - max(cue.startMS, cand.startMS)
                if overlap > 0 {
                    pairs.append(Pair(p: pi, s: si, overlap: overlap))
                }
            }
        }
        pairs.sort { $0.overlap > $1.overlap }

        for pair in pairs {
            guard !primaryTaken.contains(pair.p), !secondaryTaken.contains(pair.s) else { continue }
            let translation = sortedSecondary[pair.s].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if translation.isEmpty { continue }
            result[pair.p].translatedText = translation
            primaryTaken.insert(pair.p)
            secondaryTaken.insert(pair.s)
        }

        // ② 剩下没匹配上的，按起点最近的补（容差 1.5 秒）
        for index in result.indices where !primaryTaken.contains(index) {
            guard let si = nearestUnusedIndex(for: result[index], in: sortedSecondary, excluding: secondaryTaken) else { continue }
            let translation = sortedSecondary[si].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if translation.isEmpty { continue }
            result[index].translatedText = translation
            secondaryTaken.insert(si)
        }
        return result
    }

    /// 找起点最近且未被使用的译文
    static func nearestUnusedIndex(
        for cue: SubtitleCue,
        in sorted: [SubtitleCue],
        excluding used: Set<Int>
    ) -> Int? {
        var best: Int?
        var bestDistance = Int.max
        for (index, candidate) in sorted.enumerated() where !used.contains(index) {
            let distance = abs(candidate.startMS - cue.startMS)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return bestDistance <= 1500 ? best : nil
    }

    /// 找重叠最多的那条；没有重叠就找起点最近的（容差 1.5 秒）
    static func bestMatch(for cue: SubtitleCue, in sorted: [SubtitleCue]) -> SubtitleCue? {
        var bestOverlap = 0
        var bestOverlapCue: SubtitleCue?

        for candidate in sorted {
            let start = max(cue.startMS, candidate.startMS)
            let end = min(cue.endMS, candidate.endMS)
            let overlap = end - start
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestOverlapCue = candidate
            }
        }
        if let bestOverlapCue { return bestOverlapCue }

        // 没有重叠：按起点距离找最近的
        var nearest: SubtitleCue?
        var nearestDistance = Int.max
        for candidate in sorted {
            let distance = abs(candidate.startMS - cue.startMS)
            if distance < nearestDistance {
                nearestDistance = distance
                nearest = candidate
            }
        }
        return nearestDistance <= 1500 ? nearest : nil
    }
}
