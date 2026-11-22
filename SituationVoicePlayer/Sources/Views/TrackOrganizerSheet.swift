import SwiftUI
import UniformTypeIdentifiers

struct TrackOrganizerSheet: View {
    let work: WorkRecord
    @ObservedObject var store: LibraryStore
    var onChanged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var sections: [WorkMediaSection] = []
    @State private var collapsed = Set<String>()
    @State private var editorMode: CategoryEditorSheet.Mode?
    @State private var editingCategoryKey: String?
    @State private var deletingCategory: WorkCategory?
    @State private var editorText = ""
    @State private var errorMessage: String?
    @StateObject private var dragSession = WorkMediaDragSession()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("点组名可展开或收起，拖右侧把手可调整分组顺序。拖动音轨或附件，看到插入线后松手即可。")
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sections) { section in
                            dropZone(.header(section.id)) { groupHeader(section) }
                            if !collapsed.contains(section.id) {
                                ForEach(section.items) { item in
                                    dropZone(.item(section.id, item.id)) {
                                        VStack(spacing: 0) {
                                            itemRow(item)
                                            Divider()
                                        }
                                    }
                                }
                            }
                            dropZone(.footer(section.id)) {
                                Color.clear.frame(height: section.items.isEmpty ? 24 : 16)
                            }
                        }
                    }
                }
                .modifier(WorkGroupDropHint(session: dragSession, sections: sections))
            }
            .appPageBackground(AppTheme.painted(.clear, AppTheme.background))
            .tint(AppTheme.usesCustomPalette ? AppTheme.accent : nil)
            .appNavigationColors().navigationTitle(L10n.text("整理分组与顺序"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        editingCategoryKey = nil; editorText = ""; editorMode = .create
                    } label: { Label("新建分组", systemImage: "folder.badge.plus") }
                    .accessibilityIdentifier("organizerAddGroup")
                }
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .sheet(item: $editorMode) { mode in
                CategoryEditorSheet(mode: mode, existingTitles: sections.map { $0.category.title }, text: $editorText,
                    onConfirm: { title in saveCategory(title) }, onCancel: { editorMode = nil })
            }
            .alert("没有保存这次调整", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("好") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
            .confirmationDialog("移除这个分组？", isPresented: Binding(
                get: { deletingCategory != nil }, set: { if !$0 { deletingCategory = nil } }
            ), titleVisibility: .visible, presenting: deletingCategory) { category in
                Button("移除分组", role: .destructive) {
                    store.removeCategory(for: work, key: category.key)
                    refresh()
                }
            } message: { _ in Text("音轨回到原分类，附件回到作品附件。") }
            .onAppear { reload() }
            .onChange(of: store.contentRevision) { dragSession.invalidate(); reload() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { dragSession.invalidate() } }
            .onDisappear { dragSession.invalidate() }
        }
    }

    private func groupHeader(_ section: WorkMediaSection) -> some View {
        HStack(spacing: 8) {
            Button {
                if collapsed.remove(section.id) == nil { collapsed.insert(section.id) }
            } label: {
                HStack {
                    Image(systemName: collapsed.contains(section.id) ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold)).frame(width: 16)
                    Text(section.category.localizedTitle).font(.headline)
                    Text(section.items.isEmpty ? L10n.text("空分组") : L10n.text("\(section.items.count) 项"))
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("organizerGroup-\(section.id)")
            .accessibilityValue(collapsed.contains(section.id) ? "已收起" : "已展开")
            .contextMenu {
                Button("重命名分组") { beginRename(section.category) }
                if !section.category.isBuiltin {
                    Button("移除分组", role: .destructive) { deletingCategory = section.category }
                }
            }
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 44, height: 48).contentShape(Rectangle())
                .onDrag { beginDrag(.group(section.id)) } preview: {
                    Text(section.category.localizedTitle).padding()
                }
                .accessibilityLabel("调整\(section.category.localizedTitle)的分组顺序")
                .accessibilityIdentifier("organizerGroupHandle-\(section.id)")
                .accessibilityAdjustableAction { direction in
                    guard let index = sections.firstIndex(where: { $0.id == section.id }) else { return }
                    let destination = direction == .increment ? index + 1 : index - 1
                    guard sections.indices.contains(destination) else { return }
                    _ = moveGroup(section.id, onto: sections[destination].id, after: destination > index)
                }
        }
        .padding(.horizontal).frame(minHeight: 52)
        .background(AppTheme.card)
    }

    private func itemRow(_ item: WorkMediaItem) -> some View {
        let detail: String
        let identifier: String
        let icon: String
        switch item {
        case .track(let track):
            detail = track.fileType.uppercased(); icon = "music.note"
            identifier = "organizerTrack-\(track.id)"
        case .attachment(let record):
            detail = record.attachment.kind.title; icon = record.attachment.kind.iconName
            identifier = "organizerAttachment-\(record.id)"
        }
        return HStack {
            Image(systemName: icon).foregroundStyle(AppTheme.secondaryText).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.subheadline).lineLimit(2)
                Text(detail).font(.caption2).foregroundStyle(AppTheme.secondaryText)
            }
            Spacer()
            Image(systemName: "line.3.horizontal").foregroundStyle(AppTheme.secondaryText).accessibilityHidden(true)
        }
        .padding(.horizontal).padding(.vertical, 8).frame(minHeight: 56)
        .contentShape(Rectangle()).accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
        .onDrag { beginDrag(.item(item.id)) } preview: { Text(item.title).padding() }
    }

    private func beginDrag(_ content: WorkReorderPayload.Content) -> NSItemProvider {
        dragSession.begin(WorkReorderPayload(workID: work.id, content: content),
                          snapshot: WorkReorderSnapshot(workID: work.id, sections: sections))
    }

    private func dropZone<Content: View>(_ surface: WorkDropSurface,
                                         @ViewBuilder content: @escaping () -> Content) -> some View {
        WorkMediaDropZone(session: dragSession, surface: surface, save: saveDrop,
                          onError: { errorMessage = $0 }, content: content)
    }

    private func saveDrop(_ payload: WorkReorderPayload, _ destination: WorkDropDestination,
                          _ snapshot: WorkReorderSnapshot) throws {
        try store.applyReorder(payload, in: work, to: destination, expected: snapshot)
        refresh()
    }

    private func moveGroup(_ key: String, onto target: String, after: Bool) -> Bool {
        do {
            try saveDrop(WorkReorderPayload(workID: work.id, content: .group(key)),
                         .groupEdge(category: target, after: after),
                         WorkReorderSnapshot(workID: work.id, sections: sections))
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private func beginRename(_ category: WorkCategory) {
        editingCategoryKey = category.key
        editorText = category.title
        editorMode = .rename(original: category.title)
    }

    private func saveCategory(_ title: String) {
        do {
            if let key = editingCategoryKey { try store.renameCategoryTitle(for: work, key: key, title: title) }
            else if store.addCategory(for: work, title: title) == nil { throw LibraryEditingError.unavailable }
            editorMode = nil; refresh()
        } catch { editorMode = nil; errorMessage = error.localizedDescription }
    }

    private func refresh() { reload(); onChanged() }
    private func reload() { sections = store.organizedSections(for: work, includeEmpty: true) }
}

