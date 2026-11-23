import SwiftUI

enum LibrarySection: String, CaseIterable {
    case works = "作品", circles = "社团", performers = "声优", favorites = "收藏"
}

struct LibraryTag: Hashable, Identifiable {
    let section: LibrarySection
    let name: String?
    var id: Self { self }
    var title: String { name ?? L10n.text("待填写") }
    var orderID: String { Self.orderID(name: name) }
    static func orderID(name: String?) -> String { name.map { "name:" + $0 } ?? "missing" }

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
    @EnvironmentObject private var store: LibraryStore
    @State private var ordering = false
    @State private var message: String?
    let section: LibrarySection
    let works: [WorkRecord]
    let onSelect: (LibraryTag) -> Void
    private var scope: DirectoryOrderScope { section == .circles ? .circles : .performers }

    private var entries: [(tag: LibraryTag, count: Int)] {
        var counts = [LibraryTag: Int]()
        for work in works {
            let names = Set(LibraryTag.names(for: work, section: section))
            if names.isEmpty { counts[LibraryTag(section: section, name: nil), default: 0] += 1 }
            for name in names { counts[LibraryTag(section: section, name: name), default: 0] += 1 }
        }
        let alphabetical = counts.map { (tag: $0.key, count: $0.value) }.sorted {
            if $0.tag.name == nil { return false }
            if $1.tag.name == nil { return true }
            return NaturalSort.compare($0.tag.title, $1.tag.title)
        }
        let byID = Dictionary(uniqueKeysWithValues: alphabetical.map { ($0.tag.orderID, $0) })
        return store.directoryOrder(alphabetical.map { $0.tag.orderID }, scope: scope).compactMap { byID[$0] }
    }

    var body: some View {
        let displayed = entries
        return List {
            HStack {
                Spacer()
                Button(ordering ? L10n.text("完成") : L10n.text("调整顺序")) { ordering.toggle() }
                    .disabled(displayed.count < 2 && !ordering)
                    .accessibilityIdentifier("directoryOrderToggle")
            }.porcelainPlainRow()
            ForEach(displayed, id: \.tag) { entry in
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
                .accessibilityIdentifier("directoryRow-\(entry.tag.orderID)")
                .porcelainPlainRow()
            }
            .onMove { source, destination in
                let original = displayed.map { $0.tag.orderID }
                var ids = original
                ids.move(fromOffsets: source, toOffset: destination)
                do { try store.orderDirectory(scope, ids: ids, visibleIDs: original) }
                catch { message = error.localizedDescription }
            }
        }.listStyle(.plain)
            .porcelainListBackground(AppTheme.card)
            .environment(\.editMode, .constant(ordering ? .active : .inactive))
            .onChange(of: section) { _, _ in ordering = false }
            .onDisappear { ordering = false }
            .alert("调整顺序", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") { message = nil }
            } message: { Text(message ?? "") }
    }
}
