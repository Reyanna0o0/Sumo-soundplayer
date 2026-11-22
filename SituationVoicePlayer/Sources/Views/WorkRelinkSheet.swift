import SwiftUI
import UniformTypeIdentifiers

struct WorkRelinkSheet: View {
    let work: WorkRecord
    @ObservedObject var store: LibraryStore
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [WorkRelinkEntry] = []
    @State private var selectedFolder: URL?
    @State private var selectionRevision = UUID()
    @State private var directory: WorkRelinkDirectory?
    @State private var selections: [WorkMediaID: String] = [:]
    @State private var showPicker = false
    @State private var loading = false
    @State private var message: String?

    private var ready: Bool {
        !loading && !entries.isEmpty && selections.count == entries.count
            && Set(selections.values).count == entries.count && directory != nil
    }

    var body: some View {
        NavigationStack {
            AppList {
                Section {
                    Text("为「\(work.title)」选择现在所在的文件夹，再确认原文件与新位置的对应关系。作品资料、字幕版本、阅读位置和分组顺序都会保留。")
                        .font(.subheadline)
                    Button { showPicker = true } label: {
                        Label(directory?.url.lastPathComponent ?? L10n.text("选择文件夹…"), systemImage: "folder")
                    }
                    .disabled(loading)
                    .accessibilityIdentifier("relinkChooseFolder")
                    if loading { ProgressView("正在读取文件夹…") }
                } footer: {
                    Text("只更新文件位置，不导入额外文件。此前单独添加的内部副本无需重新配对。")
                }
                if let directory {
                    Section {
                        ForEach(entries) { entry in
                            NavigationLink {
                                RelinkFileChoice(entry: entry, files: directory.files,
                                                 selections: $selections)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.title)
                                    Text("原位置：\(entry.relativePath)")
                                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                                    Text(selections[entry.id].map { L10n.text("关联到：\($0)") } ?? L10n.text("请选择对应文件"))
                                        .font(.subheadline)
                                        .foregroundStyle(selections[entry.id] == nil ? Color.orange : Color.secondary)
                                }
                            }
                            .accessibilityIdentifier("relinkEntry-\(identifier(entry.id))")
                        }
                    } header: {
                        Text("已配对 \(selections.count) / \(entries.count)")
                    } footer: {
                        Text("相同路径或唯一同名文件已预选，请确认它们确实是原文件。改名后的文件请点进对应条目手动选择。")
                    }
                }
                if entries.isEmpty && !loading {
                    Text("这部作品没有需要重新关联的外部音轨或附件。")
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .appNavigationColors().navigationTitle(L10n.text("重新关联文件夹"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认关联") { save() }
                        .disabled(!ready)
                        .accessibilityIdentifier("confirmWorkRelink")
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    selectedFolder = url
                    selectionRevision = UUID()
                case .failure(let error):
                    if (error as? CocoaError)?.code != .userCancelled { message = error.localizedDescription }
                }
            }
            .task {
                do { entries = try store.relinkEntries(for: work) }
                catch { message = error.localizedDescription }
            }
            .task(id: selectionRevision) {
                guard let url = selectedFolder else { return }
                loading = true
                directory = nil
                selections = [:]
                do {
                    let loaded = try await Task.detached(priority: .userInitiated) {
                        try WorkRelinkDirectory(url: url)
                    }.value
                    try Task.checkCancellation()
                    entries = try store.relinkEntries(for: work)
                    directory = loaded
                    preselect(from: loaded.files)
                } catch is CancellationError {
                    return
                } catch { message = error.localizedDescription }
                loading = false
            }
            .alert("重新关联", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") { message = nil }
            } message: { Text(message ?? "") }
        }
    }

    private func preselect(from files: [ScannedFile]) {
        var used = Set<String>()
        for entry in entries {
            let compatible = files.filter { entry.accepts($0) }
            let samePath = compatible.first { $0.relativePath == entry.relativePath }
            let sameName = compatible.filter { $0.fileName == (entry.relativePath as NSString).lastPathComponent }
            if let candidate = samePath ?? (sameName.count == 1 ? sameName.first : nil),
               used.insert(candidate.relativePath).inserted {
                selections[entry.id] = candidate.relativePath
            }
        }
    }

    private func save() {
        guard ready, let directory else { return }
        do {
            try store.relinkFiles(in: work, directory: directory, selections: selections)
            onSaved()
            dismiss()
        } catch { message = error.localizedDescription }
    }

    private func identifier(_ id: WorkMediaID) -> String {
        switch id {
        case .track(let id): return "track-\(id)"
        case .attachment(let id): return "attachment-\(id)"
        }
    }
}

private struct RelinkFileChoice: View {
    let entry: WorkRelinkEntry
    let files: [ScannedFile]
    @Binding var selections: [WorkMediaID: String]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        AppList {
            Button("暂不选择") { selections.removeValue(forKey: entry.id); dismiss() }
            ForEach(files.filter { entry.accepts($0) && (search.isEmpty || $0.relativePath.localizedStandardContains(search)) }, id: \.relativePath) { file in
                let usedElsewhere = selections.contains { $0.key != entry.id && $0.value == file.relativePath }
                Button {
                    selections[entry.id] = file.relativePath
                    dismiss()
                } label: {
                    HStack {
                        Text(file.relativePath).foregroundStyle(AppTheme.primaryText)
                        Spacer()
                        if selections[entry.id] == file.relativePath { Image(systemName: "checkmark") }
                        if usedElsewhere { Text("已配对").font(.caption).foregroundStyle(AppTheme.secondaryText) }
                    }
                }
                .disabled(usedElsewhere)
            }
        }
        .appNavigationColors(contentTitle: true).navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: L10n.text("搜索文件名或路径"))
    }
}
