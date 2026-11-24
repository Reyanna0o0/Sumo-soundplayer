import SwiftUI

enum ListeningRanking: String, CaseIterable, Sendable {
    case works = "作品", creators = "创作者", voices = "声优", circles = "社团"

    /// 个人音声的排行类别（创作者、声优）。
    static let personalKinds: [ListeningRanking] = [.works, .creators]
    /// 社团合集的排行类别（作品、社团、声优）。
    static let collectionKinds: [ListeningRanking] = [.works, .circles, .voices]

    static func kinds(for scope: StatisticsScope) -> [ListeningRanking] {
        switch scope {
        case .personal: return personalKinds
        case .collection: return collectionKinds
        case .combined: return collectionKinds
        }
    }

    /// 按当前统计范围计算各类排行。个人与合集合并时，同一行只会按一种身份计入
    /// （行自身的 libraryKind），再用 creatorID 去重创作者，总秒数不会重复。
    static func allRanks(_ rows: [PlayStatRow], scope: StatisticsScope = .combined) -> [Self: [RankEntry]] {
        let scoped = scope.filter(rows).map { original -> PlayStatRow in
            var row = original
            if scope == .combined && row.libraryKind == .personal {
                row.circleName = row.creatorName
                row.seiyuuNames = row.creatorName.map { [$0] } ?? []
            }
            return row
        }
        var result: [Self: [RankEntry]] = [:]
        for kind in kinds(for: scope) {
            result[kind] = rank(kind, rows: scoped)
        }
        return result
    }

    static func rank(_ kind: ListeningRanking, rows: [PlayStatRow]) -> [RankEntry] {
        switch kind {
        case .works: return StatsAggregator.topWorks(rows, limit: .max)
        case .voices:
            return StatsAggregator.topSeiyuu(rows, limit: .max) { row in
                row.libraryKind == .personal ? .creator(row.creatorID) : .voice
            }
        case .circles:
            return StatsAggregator.topCircles(rows, limit: .max) { row in
                row.libraryKind == .personal ? .creator(row.creatorID) : .circle
            }
        case .creators: return topCreators(rows, limit: .max)
        }
    }

    /// 创作者排行：复用 PlayStatRow / RankEntry。每行只计一次，
    /// 有 creatorID 时按 ID 归并（名字取出现过的 creatorName），否则按名字归并。
    static func topCreators(_ rows: [PlayStatRow], limit: Int) -> [RankEntry] {
        struct Agg {
            var seconds = 0
            var works = Set<Int64>()
            var name = ""
        }
        var byID: [Int64: Agg] = [:]
        var byName: [String: Agg] = [:]
        for row in rows where row.workID > 0 && row.libraryKind == .personal {
            let name = row.creatorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let creatorID = row.creatorID {
                var agg = byID[creatorID] ?? Agg()
                agg.seconds += row.seconds
                agg.works.insert(row.workID)
                if agg.name.isEmpty { agg.name = name }
                byID[creatorID] = agg
            } else if !name.isEmpty {
                var agg = byName[name] ?? Agg()
                agg.seconds += row.seconds
                agg.works.insert(row.workID)
                byName[name] = agg
            }
        }
        var entries: [RankEntry] = []
        for (id, agg) in byID {
            entries.append(RankEntry(name: agg.name.isEmpty ? L10n.text("创作者 #\(id)") : agg.name,
                                     seconds: agg.seconds, workCount: agg.works.count, attribution: .creator(id)))
        }
        for (name, agg) in byName {
            entries.append(RankEntry(name: name, seconds: agg.seconds, workCount: agg.works.count, attribution: .creator(nil)))
        }
        entries.sort { a, b in
            if a.seconds != b.seconds { return a.seconds > b.seconds }
            return a.name < b.name
        }
        return Array(entries.prefix(max(0, limit)))
    }
}

/// The actual creator ID travels with its listening rows. A name shared by
/// multiple identities receives a neutral symbol, including in a combined report.
struct ListeningRankBadge: View {
    let subject: RankAttribution
    let name: String
    let avatarPath: String?
    let size: CGFloat
    let symbolTint: Color?

    init?(entry: RankEntry, store: LibraryStore, size: CGFloat, symbolTint: Color? = nil) {
        guard let subject = entry.attribution else { return nil }
        self.subject = subject
        self.name = entry.name
        self.size = size
        self.symbolTint = symbolTint
        if case .creator(let id) = subject, let creator = store.creator(id: id) {
            avatarPath = store.creatorAvatarPath(creator)
        } else {
            avatarPath = nil
        }
    }

    var body: some View {
        Group {
            switch subject {
            case .creator:
                CreatorAvatarView(path: avatarPath, name: name, size: size,
                                  placeholderStyle: symbolTint.map { AnyShapeStyle($0) } ?? AppTheme.secondaryText)
            case .voice:
                LibraryTagSymbol(section: .performers)
            case .circle:
                LibraryTagSymbol(section: .circles)
            case .mixed:
                Image(systemName: "person.2")
            }
        }
        .foregroundColor(symbolTint)
        .font(.system(size: size * 0.52))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ListeningRankRow: View {
    let position: Int
    let entry: RankEntry
    var badge: ListeningRankBadge? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(position)").font(.subheadline.monospacedDigit()).foregroundStyle(AppTheme.secondaryText)
                .frame(minWidth: 20, alignment: .leading)
            if let badge {
                badge.alignmentGuide(.firstTextBaseline) { $0.height / 2 + 5 }
            }
            Text(entry.name).font(.body).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(listeningDuration(entry.seconds)).font(.subheadline.monospacedDigit())
                .foregroundStyle(AppTheme.secondaryText).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ExpandableListeningRanking: View {
    let kind: ListeningRanking
    let entries: [RankEntry]
    let previewLimit: Int
    var onDarkReviewCard = false
    @EnvironmentObject private var store: LibraryStore
    @State private var expanded = false

    var body: some View {
        if entries.isEmpty {
            Text("这段时间没有可归属的\(L10n.key(kind.rawValue))记录。").font(.subheadline).foregroundStyle(AppTheme.secondaryText)
        } else {
            let count = expanded ? entries.count : min(entries.count, previewLimit)
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(0..<count, id: \.self) { index in
                    ListeningRankRow(position: index + 1, entry: entries[index],
                                     badge: ListeningRankBadge(entry: entries[index], store: store, size: 32,
                                                               symbolTint: onDarkReviewCard ? AppTheme.iconTint : nil))
                        .foregroundColor(onDarkReviewCard ? .white : nil)
                        .accessibilityIdentifier("rank-\(kind.rawValue)-\(index + 1)")
                }
                if entries.count > previewLimit {
                    Button {
                        expanded.toggle()
                    } label: {
                        HStack {
                            Text(expanded ? L10n.text("收起") : L10n.text("展开全部（\(entries.count)）"))
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                        }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier("expandRanks-\(kind.rawValue)")
                }
            }
        }
    }
}
