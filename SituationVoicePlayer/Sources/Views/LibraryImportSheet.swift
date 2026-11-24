import SwiftUI
import UniformTypeIdentifiers

struct LibraryImportSheet: View {
    @ObservedObject var store: LibraryStore
    let initialLibrary: MediaLibraryKind
    @Environment(\.dismiss) private var dismiss
    @State private var duplicateZIP = false
    @State private var importIndependentCopy = false
    @State private var showNameConflictConfirmation = false
    private enum InputKind: String, CaseIterable { case audio = "音频文件", video = "视频文件", folder = "文件夹", zip = "ZIP 压缩包" }
    @State private var library: MediaLibraryKind
    @State private var kind: InputKind
    @State private var creatorID: Int64?
    @State private var showCreatorEditor = false
    @State private var showPicker = false
    @State private var showSoundgasm = false
    @State private var selectedURLs: [URL] = []
    @State private var archive: PreparedZIPImport?
    @State private var grouping: ScanOptions.Grouping = .singleWork
    @State private var preview: LibraryStore.ImportPreview?
    @State private var revision = UUID()
    @State private var preparing = false
    @State private var importing = false
    @State private var loadingPreview = false
    @State private var progressText = ""
    @State private var errorText: String?
    @State private var operation: Task<Void, Never>?

    init(store: LibraryStore, initialLibrary: MediaLibraryKind) {
        self.store = store; self.initialLibrary = initialLibrary
        _library = State(initialValue: initialLibrary)
        _kind = State(initialValue: initialLibrary == .personal ? .audio : .folder)
    }
    private var busy: Bool { preparing || importing }
    /// 已选文件中有非视频时不允许提交，避免只导入一部分。
    private var hasUnsupportedVideo: Bool {
        kind == .video && selectedURLs.contains { WorkAttachmentFinder.kind(forExtension: $0.pathExtension) != .video }
    }
    private var ready: Bool {
        !busy && !loadingPreview && !selectedURLs.isEmpty && preview != nil
            && (!duplicateZIP || importIndependentCopy) && preview?.errorMessage == nil && (preview?.workCount ?? 0) > 0 && !hasUnsupportedVideo
    }
    private var allowedTypes: [UTType] {
        switch kind {
        case .audio: return [.audio]
        case .video: return [.movie, .mpeg4Movie, .quickTimeMovie, .avi]
        case .folder: return [.folder]
        case .zip: return [.zip]
        }
    }

    var body: some View {
        NavigationStack {
            AppForm {
                if duplicateZIP {
                    Section {
                        Text("新副本会添加编号；旧作品、字幕编辑和统计保留在原作品中，不会转移或覆盖。会额外占用存储空间。")
                            .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                    }
                }
                if let titles = preview?.conflictingTitles, !titles.isEmpty, !loadingPreview {
                    Section("存在同名作品") {
                        Text("其他来源或本批次中有同名作品。继续导入会保留同名，不会合并或覆盖已有作品。")
                            .font(.footnote)
                        ForEach(titles, id: \.self) { Text($0).font(.subheadline) }
                    }
                }
                Section {
                    Button("从 Soundgasm 链接导入", systemImage: "link") { showSoundgasm = true }
                        .accessibilityIdentifier("chooseSoundgasm")
                }.disabled(busy)
                Section("导入到") {
                    Picker("媒体库", selection: $library) {
                        ForEach(MediaLibraryKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.accessibilityIdentifier("libraryImportLibrary")
                    if library == .personal {
                        Picker("创作者", selection: $creatorID) {
                            Text("暂不指定").tag(Int64?.none)
                            ForEach(store.creators) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Button("新建创作者") { showCreatorEditor = true }
                    }
                }.disabled(busy)
                Section {
                    Picker("选择类型", selection: $kind) {
                        ForEach(InputKind.allCases, id: \.self) { Text(L10n.key($0.rawValue)).tag($0) }
                    }
                    .accessibilityIdentifier("libraryImportKind")
                    .onChange(of: kind) { _, _ in resetSelection() }
                    Button { showPicker = true } label: {
                        Label(selectedURLs.isEmpty ? L10n.text("选择\(L10n.key(kind.rawValue))…") : L10n.text("重新选择…"), systemImage: "plus")
                    }.accessibilityIdentifier("libraryImportChooseFiles")
                    ForEach(Array(selectedURLs.enumerated()), id: \.offset) { _, url in
                        Text(url.lastPathComponent).font(.subheadline).lineLimit(2)
                    }
                } footer: {
                    Text(kind == .audio ? L10n.text("每个音频建立一个作品，文件复制进 App，原文件保持原样。") :
                         kind == .video ? L10n.text("每个视频建立一个作品（可多选），原视频复制进 App，原文件保持原样。") :
                         kind == .zip ? L10n.text("支持普通 ZIP，暂不支持密码和分卷包。解压完成后先预览，确认才加入媒体库。") :
                         L10n.text("直接关联所选文件夹中的原文件。以后改名或移动，可在作品菜单重新关联。"))
                }.disabled(busy)
                if preparing || importing {
                    Section { ProgressView(progressText.isEmpty ? L10n.text("正在处理…") : progressText) }
                }
                if !selectedURLs.isEmpty && (kind == .folder || kind == .zip) && !preparing {
                    Section {
                        Picker("作品划分方式", selection: $grouping) {
                            Text("整个文件夹算一个作品").tag(ScanOptions.Grouping.singleWork)
                            Text("每个子文件夹一个作品").tag(ScanOptions.Grouping.childrenAsWorks)
                            Text("每个音频/视频文件算一个作品").tag(ScanOptions.Grouping.filesAsWorks)
                            Text("按目录自动判断").tag(ScanOptions.Grouping.automatic)
                        }
                        .pickerStyle(.inline)
                    } header: { Text("作品划分") } footer: {
                        if grouping == .filesAsWorks {
                            Text("包含所有子文件夹，每个媒体文件独立成作。同目录同名台本、字幕和图片随对应作品；多媒体共用明确命名的封面，无法确认归属的资料不自动分配。已有作品不会自动拆分。")
                        }
                    }.disabled(importing)
                }
                if !selectedURLs.isEmpty && !preparing {
                    Section("导入预览") {
                        if loadingPreview { ProgressView("正在识别作品…") }
                        else if let preview {
                            if let error = preview.errorMessage { Text(error).foregroundStyle(.orange) }
                            else if hasUnsupportedVideo { Text("所选文件中包含非视频文件，请重新选择视频。").foregroundStyle(.orange) }
                            else {
                                LabeledContent("作品", value: "\(preview.workCount)")
                                LabeledContent("音轨", value: "\(preview.trackCount)")
                                if preview.videoCount > 0 { LabeledContent("视频", value: "\(preview.videoCount)") }
                                LabeledContent("字幕文件", value: "\(preview.subtitleCount)")
                                LabeledContent("封面", value: "\(preview.coverCount)")
                                if !preview.subtitleFiles.isEmpty {
                                    DisclosureGroup("字幕文件") {
                                        ForEach(Array(preview.subtitleFiles.enumerated()), id: \.offset) { _, name in Text(name) }
                                    }
                                }
                                if !preview.unmatchedFiles.isEmpty {
                                    DisclosureGroup("未自动收录的文件") {
                                        Text("未找到唯一匹配的音轨或可读取的时间字幕；台本可在作品中手动配对。")
                                            .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                                        ForEach(Array(preview.unmatchedFiles.enumerated()), id: \.offset) { _, name in Text(name) }
                                    }
                                }
                                ForEach(Array(preview.titles.enumerated()), id: \.offset) { _, title in
                                    Text(title).font(.caption).lineLimit(2)
                                }
                                if preview.workCount > preview.titles.count {
                                    Text("还有 \(preview.workCount - preview.titles.count) 个作品").font(.caption)
                                }
                            }
                        }
                    }
                }
                if let errorText { Section { Text(errorText).font(.callout).foregroundStyle(.orange) } }
            }
            .appNavigationColors().navigationTitle(L10n.text("导入作品"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(duplicateZIP ? L10n.text("这个 ZIP 已导入") : L10n.text("导入作品"))
                        .font(.headline).fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack { cancelButton; Spacer(); importButton }
                        VStack(alignment: .leading) { cancelButton; importButton }
                    }
                    if duplicateZIP {
                        Toggle("另存为新作品", isOn: $importIndependentCopy)
                            .font(.subheadline).disabled(busy || loadingPreview)
                            .accessibilityIdentifier("libraryImportIndependentCopy")
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.background)
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [AppTheme.background, AppTheme.background.opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 18).offset(y: 18)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
            }
            .interactiveDismissDisabled(busy)
            .alert("存在同名作品", isPresented: $showNameConflictConfirmation) {
                Button("取消", role: .cancel) {}
                Button("仍然导入") { submit(confirmedNames: true) }
            } message: {
                Text("其他来源或本批次中有同名作品。继续导入会保留同名，不会合并或覆盖已有作品。")
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: allowedTypes,
                          allowsMultipleSelection: kind == .audio || kind == .video) { result in
                switch result {
                case .success(let urls): select(urls)
                case .failure(let error):
                    if (error as? CocoaError)?.code != .userCancelled { errorText = error.localizedDescription }
                }
            }
            .sheet(isPresented: $showCreatorEditor) {
                CreatorEditorSheet(creator: nil, store: store) { creatorID = $0 }
            }
            .sheet(isPresented: $showSoundgasm) {
                SoundgasmImportSheet(store: store) { dismiss() }
            }
            .task(id: "\(revision)-\(grouping.rawValue)-\(library.rawValue)") { await refreshPreview() }
            .onDisappear { operation?.cancel(); if !importing { try? archive?.dispose() } }
        }
    }

    private var cancelButton: some View {
        Button { operation?.cancel(); dismiss() } label: {
            Text("取消").fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.disabled(importing && kind == .folder)
    }
    private var importButton: some View {
        Button { submit() } label: {
            Text("确认导入").fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }.disabled(!ready).accessibilityIdentifier("libraryImportConfirm")
    }

    private func resetSelection() {
        operation?.cancel(); operation = nil
        try? archive?.dispose(); archive = nil
        duplicateZIP = false; importIndependentCopy = false; showNameConflictConfirmation = false
        selectedURLs = []; preview = nil; errorText = nil; preparing = false
        revision = UUID()
    }

    private func select(_ urls: [URL]) {
        resetSelection()
        guard !urls.isEmpty else { return }
        selectedURLs = urls
        if kind == .zip {
            preparing = true; progressText = L10n.text("正在读取 ZIP…")
            operation = Task {
                do {
                    let prepared = try await ZIPArchiveStager.prepare(from: urls[0]) { value in
                        Task { @MainActor in
                            progressText = L10n.text("正在处理 ZIP：\(ByteCountFormatter.string(fromByteCount: value.completedBytes, countStyle: .file))")
                        }
                    }
                    try Task.checkCancellation()
                    archive = prepared; preparing = false; revision = UUID()
                } catch {
                    preparing = false
                    if !(error is CancellationError) { errorText = error.localizedDescription }
                }
            }
        } else { revision = UUID() }
    }

    private func refreshPreview() async {
        guard !selectedURLs.isEmpty, !preparing else { return }
        loadingPreview = true
        duplicateZIP = false; importIndependentCopy = false; showNameConflictConfirmation = false
        let result: LibraryStore.ImportPreview
        switch kind {
        case .audio:
            result = .init(workCount: selectedURLs.count, trackCount: selectedURLs.count,
                           titles: selectedURLs.prefix(8).map { $0.deletingPathExtension().lastPathComponent })
        case .video:
            result = .init(workCount: selectedURLs.count, trackCount: 0, videoCount: selectedURLs.count,
                           titles: selectedURLs.prefix(8).map { $0.deletingPathExtension().lastPathComponent })
        case .folder:
            result = await store.makePreview(url: selectedURLs[0], grouping: grouping, libraryKind: library)
        case .zip:
            guard let archive else { loadingPreview = false; return }
            duplicateZIP = (try? store.hasImportedZIP(archive.archiveSHA256, library: library)) ?? false
            result = await store.makeZIPPreview(archive, grouping: grouping)
        }
        guard !Task.isCancelled else { return }
        preview = result; loadingPreview = false
    }

    private func submit(confirmedNames: Bool = false) {
        guard ready else { return }
        if !confirmedNames, kind == .folder, preview?.conflictingTitles.isEmpty == false {
            showNameConflictConfirmation = true
            return
        }
        importing = true; errorText = nil; progressText = L10n.text("正在导入…")
        operation = Task {
            do {
                switch kind {
                case .audio: try await store.importAudioWorks(selectedURLs, library: library, creatorID: creatorID)
                case .video: try await store.importVideoWorks(selectedURLs, library: library, creatorID: creatorID)
                case .folder:
                    await store.importFolder(url: selectedURLs[0], grouping: grouping, libraryKind: library, creatorID: creatorID)
                    if case .failed(let message) = store.phase { throw WorkRelinkError.message(message) }
                    guard case .done = store.phase else { throw CancellationError() }
                    store.setCurrentLibrary(library)
                case .zip:
                    guard let archive else { throw WorkRelinkError.message(L10n.text("请重新选择 ZIP。")) }
                    try await store.importZIP(archive, grouping: grouping, library: library, creatorID: creatorID, importIndependentCopy: importIndependentCopy)
                }
                importing = false; dismiss()
            } catch {
                importing = false
                if kind == .zip {
                    try? archive?.dispose(); archive = nil
                    duplicateZIP = false; importIndependentCopy = false; showNameConflictConfirmation = false
        selectedURLs = []; preview = nil; revision = UUID()
                }
                if !(error is CancellationError) {
                    errorText = error.localizedDescription + (kind == .zip ? L10n.text(" 请重新选择 ZIP 后再试。") : "")
                }
            }
        }
    }
}
