import SwiftUI
import UniformTypeIdentifiers
import ResourceAccessCore

struct NetworkImportView: View {
    let source: NetworkLibrarySource
    @ObservedObject var store: LibraryStore
    @State private var folder = ResourcePath.root
    @State private var entries: [ResourceEntry] = []
    @State private var selected = Set<ResourcePath>()
    @State private var busy = false
    @State private var message: String?
    @State private var importedMessage: String?
    @State private var showImport = false
    @State private var refreshID = UUID()
    @State private var loadGeneration = UUID()

    private var selection: [ResourcePath] {
        selected.sorted { $0.string.localizedStandardCompare($1.string) == .orderedAscending }
    }

    var body: some View {
        AppList {
            Section {
                if !folder.components.isEmpty {
                    Button("返回上级", systemImage: "arrow.up") {
                        folder = (try? ResourcePath(folder.components.dropLast().joined(separator: "/"))) ?? .root
                    }.disabled(busy).accessibilityIdentifier("networkParentDirectory")
                }
                Text(folder.string.isEmpty ? source.name : folder.string)
                    .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                if busy { ProgressView("正在读取目录…") }
                Button("刷新", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    .disabled(busy).accessibilityIdentifier("networkRefreshDirectory")
            } footer: {
                Text("点文件夹进入，勾选音频后作为一个作品导入。只读取当前这一层，不自动递归扫描。")
            }
            Section {
                ForEach(entries, id: \.path) { entry in
                    if entry.metadata.isDirectory {
                        Button {
                            folder = entry.path
                        } label: {
                            Label(entry.path.components.last ?? "", systemImage: "folder")
                        }.disabled(busy)
                    } else if isAudio(entry.path) {
                        Button {
                            if selected.contains(entry.path) { selected.remove(entry.path) }
                            else if selected.count < 500 { selected.insert(entry.path) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(entry.path) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.path.components.last ?? "")
                                    if let size = entry.metadata.size {
                                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                                    }
                                }
                            }.foregroundStyle(AppTheme.primaryText)
                        }.disabled(busy).accessibilityIdentifier("networkFile-\(entry.path.string)")
                            .accessibilityAddTraits(selected.contains(entry.path) ? .isSelected : [])
                    }
                }
                if !busy && entries.filter({ $0.metadata.isDirectory || isAudio($0.path) }).isEmpty {
                    Text("当前目录没有 MP3、M4A 或 WAV 文件。").foregroundStyle(AppTheme.secondaryText)
                }
            } header: { Text("文件") }
            if !selected.isEmpty {
                Section {
                    Text(L10n.text("已选择 \(selected.count) 个音频"))
                    Button("作为一个作品导入…") { showImport = true }
                        .disabled(busy).accessibilityIdentifier("networkImportSelection")
                    Button("取消全部选择") { selected.removeAll() }.disabled(busy)
                } footer: {
                    Text("选择可跨当前来源内的目录保留。作品的名称、库与创作者将在下一步确认。")
                }
            }
        }
        .appPageBackground().appNavigationColors().navigationTitle(source.name).navigationBarTitleDisplayMode(.inline)
        .task(id: "\(folder.string)|\(refreshID)") { await loadDirectory() }
        .sheet(isPresented: $showImport) {
            NetworkImportDetails(source: source, paths: selection, store: store) { library in
                selected.removeAll()
                importedMessage = L10n.text("已导入到\(library.displayName)。来源离线时仍可查看作品资料；音频播放需要连接来源。")
            }
        }
        .alert("读取未完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("确定", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .alert("导入完成", isPresented: Binding(get: { importedMessage != nil }, set: { if !$0 { importedMessage = nil } })) {
            Button("确定", role: .cancel) { importedMessage = nil }
        } message: { Text(importedMessage ?? "") }
    }

    private func isAudio(_ path: ResourcePath) -> Bool {
        NetworkLibraryService.supportedAudio.contains((path.string as NSString).pathExtension.lowercased())
    }

    @MainActor private func loadDirectory() async {
        guard NetworkLibraryService.shared.sources.contains(source) else {
            message = NetworkLibraryError.changedDuringOperation.localizedDescription; return
        }
        let requested = folder
        let generation = UUID()
        loadGeneration = generation
        busy = true; entries = []
        defer { if loadGeneration == generation { busy = false } }
        do {
            let adapter = try await NetworkLibraryService.shared.adapter(for: source.id)
            let result: [ResourceEntry]
            if let path = source.directHTTPPath {
                result = [ResourceEntry(path: path, metadata: try await adapter.metadata(at: path))]
            } else { result = try await adapter.listChildren(at: requested) }
            try Task.checkCancellation()
            guard folder == requested, loadGeneration == generation else { return }
            entries = result.sorted {
                if $0.metadata.isDirectory != $1.metadata.isDirectory { return $0.metadata.isDirectory }
                return $0.path.string.localizedStandardCompare($1.path.string) == .orderedAscending
            }
        } catch { if !Task.isCancelled { message = NetworkLibraryService.message(for: error) } }
    }
}

private struct NetworkImportDetails: View {
    let source: NetworkLibrarySource
    let paths: [ResourcePath]
    @ObservedObject var store: LibraryStore
    let onImported: (MediaLibraryKind) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var library: MediaLibraryKind
    @State private var creatorID: Int64?
    @State private var cover: String?
    @State private var showCoverPicker = false
    @State private var busy = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?
    @State private var committed = false

    init(source: NetworkLibrarySource, paths: [ResourcePath], store: LibraryStore,
         onImported: @escaping (MediaLibraryKind) -> Void) {
        self.source = source; self.paths = paths; self.store = store; self.onImported = onImported
        let suggested = paths.count == 1 ? ((paths.first?.components.last ?? "") as NSString).deletingPathExtension
            : paths.first?.components.dropLast().last ?? source.name
        _title = State(initialValue: suggested)
        _library = State(initialValue: store.currentLibrary)
    }

    var body: some View {
        NavigationStack {
            AppForm {
                Section {
                    TextField("作品名称", text: $title).accessibilityIdentifier("networkImportTitle")
                    Picker("导入到", selection: $library) {
                        ForEach(MediaLibraryKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.accessibilityIdentifier("networkImportLibrary")
                    if library == .personal {
                        Picker("创作者", selection: $creatorID) {
                            Text("待填写").tag(Optional<Int64>.none)
                            ForEach(store.creators) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                } footer: {
                    Text("沿用现有媒体库分类；导入后可在作品详情继续编辑资料、分组和顺序。")
                }
                if library == .collection {
                    Section {
                        if let cover, let path = WorkAssetImporter.path(for: cover) {
                            CoverImageView(path: path, cornerRadius: 10, contentMode: .fit)
                                .frame(height: 150).frame(maxWidth: .infinity)
                        }
                        Button("选择本地封面…", systemImage: "photo") { showCoverPicker = true }
                            .accessibilityIdentifier("networkImportCover")
                        if cover != nil { Button("移除所选封面") { discardCover() } }
                    } footer: { Text("封面会复制到手机，来源离线时仍可显示。") }
                } else {
                    Section { Text("个人音声沿用创作者的本地头像和封面，可在创作者资料中修改。") }
                }
                Section {
                    ForEach(paths, id: \.self) { Text($0.string).font(.subheadline) }
                } header: { Text(L10n.text("已选音频 · \(paths.count)")) } footer: {
                    Text("保存作品资料和音频位置，播放时从来源读取。此次导入不会下载完整音频。")
                }
                if busy { Section { ProgressView("正在核对所选音频…") } }
            }
            .disabled(busy)
            .appPageBackground().appNavigationColors().navigationTitle(L10n.text("导入网络作品"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { task?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { save() }.disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("networkConfirmImport")
                }
            }
            .fileImporter(isPresented: $showCoverPicker, allowedContentTypes: [.image]) { result in
                do {
                    guard !LibraryBackupCoordinator.shared.isBusy && !LibraryBackupCoordinator.shared.restoreReady else {
                        throw NetworkLibraryError.backupInProgress
                    }
                    let url = try result.get()
                    let copied = try WorkAssetImporter.copyCover(from: url)
                    discardCover(); cover = copied
                } catch {
                    if let own = error as? NetworkLibraryError { message = own.localizedDescription }
                    else if (error as? CocoaError)?.code != .userCancelled { message = L10n.text("无法读取这张图片，请选择其他封面。") }
                }
            }
            .alert("导入未完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("确定", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
            .onDisappear { task?.cancel(); if !committed { discardCover() } }
            .interactiveDismissDisabled(busy)
        }
    }

    private func discardCover() {
        if let cover { WorkAssetImporter.remove(cover) }
        cover = nil
    }

    private func save() {
        busy = true
        task = Task {
            do {
                _ = try await NetworkLibraryService.shared.importSelection(source: source, paths: paths,
                    title: title, library: library, creatorID: creatorID,
                    coverAssetPath: library == .collection ? cover : nil)
                if library == .personal { discardCover() }
                committed = true
                store.reload(); onImported(library); dismiss()
            } catch { if !Task.isCancelled { message = NetworkLibraryService.message(for: error) } }
            busy = false
        }
    }
}
