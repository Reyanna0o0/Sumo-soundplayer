import SwiftUI

/// Shared actions for the existing favorites/playlist/clip pages. Management
/// stays in the page; only entering a new name needs a small editor sheet.
struct CollectionManagementActions: ViewModifier {
    let kind: CollectionKind
    @EnvironmentObject private var store: LibraryStore
    @Binding var editing: NamedCollection?
    @Binding var removing: NamedCollection?
    @Binding var message: String?

    private var groups: [NamedCollection] { store.collections(for: kind) }
    private var defaultName: String { groups.first { $0.id == kind.defaultID }?.name ?? L10n.text("默认分类") }

    func body(content: Content) -> some View {
        content
            .porcelainSheet(item: $editing) { group in
                CollectionNameEditor(name: group.name, title: L10n.text("重命名分类")) { name in
                    try store.renameCollection(kind, id: group.id, name: name)
                }
            }
            .alert("删除「\(removing?.name ?? "")」？",
                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                presenting: removing) { group in
                    Button("移入「\(defaultName)」并删除分类", role: .destructive) {
                        do { try store.deleteCollection(kind, id: group.id) }
                        catch { message = error.localizedDescription }
                    }
                    Button("取消", role: .cancel) {}
                }
            .alert("分类操作未完成", isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } }
            )) {
                Button("好") { message = nil }
            } message: { Text(message ?? "") }
    }
}

struct CollectionRenameLabel: View {
    let group: NamedCollection
    let rename: () -> Void

    var body: some View {
        Button(action: rename) {
            HStack(spacing: 6) {
                Text(group.name).lineLimit(2)
                Image(systemName: "pencil").font(.caption).opacity(0.7)
            }
            .frame(minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
            .foregroundStyle(AppTheme.primaryText)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(L10n.text("重命名") + group.name)
        .accessibilityIdentifier("renameCollection-\(group.id)")
    }
}

struct CollectionDeleteButton: View {
    let group: NamedCollection
    let remove: () -> Void

    var body: some View {
        Button(role: .destructive, action: remove) {
            Image(systemName: "trash").frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
        .accessibilityLabel(L10n.text("删除") + group.name)
        .accessibilityIdentifier("deleteCollection-\(group.id)")
    }
}

struct CollectionContextActions: View {
    let group: NamedCollection
    let kind: CollectionKind
    let rename: () -> Void
    let remove: () -> Void

    var body: some View {
        Button("重命名", systemImage: "pencil", action: rename)
            .accessibilityIdentifier("contextRenameCollection-\(group.id)")
        if group.id != kind.defaultID {
            Button("删除分类", systemImage: "trash", role: .destructive, action: remove)
                .accessibilityIdentifier("contextDeleteCollection-\(group.id)")
        }
    }
}

struct CollectionNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var message: String?
    let title: String
    let onSave: (String) throws -> Void

    init(name: String = "", title: String, onSave: @escaping (String) throws -> Void) {
        _name = State(initialValue: name)
        self.title = title
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            AppForm {
                TextField("分类名称", text: $name)
                    .accessibilityIdentifier("collectionName")
                if let message { Text(message).foregroundStyle(.red) }
            }
            .appNavigationColors().navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do { try onSave(name); dismiss() }
                        catch { message = error.localizedDescription }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
