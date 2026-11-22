import SwiftUI

enum LibrarySection: String, CaseIterable {
    case works = "作品", circles = "社团", performers = "声优", favorites = "收藏"
}

struct LibraryTag: Hashable, Identifiable {
    let section: LibrarySection
    let name: String?
    var id: Self { self }
    var title: String { name ?? L10n.text("待填写") }

    static func names(for work: WorkRecord, section: LibrarySection) -> [String] {
        let values = section == .circles ? [work.circleName ?? ""] : work.seiyuuNames
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    func contains(_ work: WorkRecord) -> Bool {
        let names = Self.names(for: work, section: section)
        return name.map(names.contains) ?? names.isEmpty
    }
}

struct LibraryTagSymbol: View {
    let section: LibrarySection

    var body: some View {
        let symbol = Image(systemName: section == .circles ? "person.3" : "mic")
        if AppTheme.isPurple { symbol.foregroundStyle(AppTheme.iconTint) }
        else { symbol }
    }
}

struct LibraryTagView: View {
    let section: LibrarySection
    let works: [WorkRecord]
    let onSelect: (LibraryTag) -> Void

    private var entries: [(tag: LibraryTag, count: Int)] {
        var counts = [LibraryTag: Int]()
        for work in works {
            let names = Set(LibraryTag.names(for: work, section: section))
            if names.isEmpty { counts[LibraryTag(section: section, name: nil), default: 0] += 1 }
            for name in names { counts[LibraryTag(section: section, name: name), default: 0] += 1 }
        }
        return counts.map { (tag: $0.key, count: $0.value) }.sorted {
            if $0.tag.name == nil { return false }
            if $1.tag.name == nil { return true }
            return NaturalSort.compare($0.tag.title, $1.tag.title)
        }
    }

    var body: some View {
        List(entries, id: \.tag) { entry in
            Button { onSelect(entry.tag) } label: {
                HStack(spacing: 12) {
                    LibraryTagSymbol(section: section).frame(width: 24)
                    Text(entry.tag.title).foregroundStyle(AppTheme.primaryText)
                    Spacer()
                    Text("\(entry.count) 部").foregroundStyle(AppTheme.secondaryText)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.tertiaryText)
                }
                .padding(.leading, section == .circles ? 10 : 0)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .porcelainPlainRow()
        }.listStyle(.plain)
            .porcelainListBackground(AppTheme.card)
    }
}
