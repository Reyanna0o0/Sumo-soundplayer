import SwiftUI
import UniformTypeIdentifiers

/// 作品详情：曲目按分组显示，支持手动调整
struct WorkDetailView: View {
    enum Presentation { case collection, personal }

    let work: WorkRecord
    @ObservedObject var store: LibraryStore
    var presentation: Presentation = .collection

    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var subtitles: SubtitleController
    @Environment(\.scenePhase) private var scenePhase

    @State private var sections: [WorkMediaSection] = []
    @State private var pendingRemoval: TrackRecord?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var allCategories: [WorkCategory] = []
    @StateObject private var dragSession = WorkMediaDragSession()

    /// 当前正在编辑的分组（新建 / 重命名），nil 表示不显示
    @State private var showOrganizer = false
    /// 正在等待选择字幕文件的曲目
    @State private var subtitlePickerTrack: TrackRecord?
    @State private var subtitleImportMessage: String?
    @State private var subtitleReceipt: SubtitleImportReceipt?
    @State private var showFavoritePicker = false
    @State private var showMetadataEditor = false
    @State private var showRelinkSheet = false
    @State private var showAudioRelinkSheet = false
    @State private var showScriptImporter = false
    @State private var showFileImporter = false
    @State private var fileImportKind = FileImportKind.media
    @State private var isImportingAsset = false
    @State private var assetMessage: String?
    @State private var refreshedWork: WorkRecord?

    private enum FileImportKind { case media, subtitle }
    private var currentWork: WorkRecord {
        store.works.first { $0.id == work.id } ?? refreshedWork ?? work
    }
    @State private var editorMode: CategoryEditorSheet.Mode?
    @State private var editorText: String = ""
    @State private var editingCategoryKey: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                WorkFileLinkNotice(work: currentWork, store: store) {
                    if presentation == .personal { showAudioRelinkSheet = true }
                    else { showRelinkSheet = true }
                }
                if presentation == .personal {
                    personalActions
                    personalContent
                } else {
                    contentSections
                    pathSection
                }
                if !store.directLinks(for: currentWork).isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("导入来源").font(.headline).foregroundStyle(AppTheme.headingInk())
                        ForEach(store.directLinks(for: currentWork), id: \.sourceURL) { metadata in
                            DirectLinkDetails(metadata: metadata)
                            Divider().overlay(AppTheme.painted(.clear, AppTheme.separator))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 5)
            .padding(.bottom, 12)
        }
        .accessibilityIdentifier("workDetailScroll")
        .modifier(WorkGroupDropHint(session: dragSession, sections: sections))
        .appPageBackground()
        .appNavigationColors().navigationTitle(presentation == .personal ? L10n.text("作品资料") : L10n.text("作品详情"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .porcelainSheet(item: $editorMode) { mode in
            CategoryEditorSheet(
                mode: mode,
                existingTitles: allCategories.map(\.title),
                text: $editorText,
                onConfirm: { title in
                    commitEditor(mode: mode, title: title)
                },
                onCancel: {
                    editorMode = nil
                }
            )
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: fileImportKind == .media
        ) { result in
            handleFileImport(result)
        }
        .porcelainSheet(isPresented: $showFavoritePicker) { WorkFavoritePicker(workID: work.id) }
        .porcelainSheet(isPresented: $showMetadataEditor) {
            WorkMetadataEditorSheet(work: currentWork, store: store, onSaved: reloadSections)
        }
        .porcelainSheet(isPresented: $showRelinkSheet) {
            WorkRelinkSheet(work: currentWork, store: store, onSaved: reloadSections)
        }
        .porcelainSheet(isPresented: $showAudioRelinkSheet) {
            PersonalAudioRelinkSheet(work: currentWork, store: store)
        }
        .porcelainSheet(isPresented: $showScriptImporter) {
            WorkScriptImportSheet(work: currentWork, store: store, onImported: reloadSections)
        }
        .overlay {
            if isImportingAsset {
                ProgressView("正在添加文件…")
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .confirmationDialog("从作品中移除这条音轨？", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible, presenting: pendingRemoval) { track in
            Button("移除音轨", role: .destructive) {
                do { try store.removeTrack(track, in: currentWork); reloadSections() }
                catch { assetMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: { track in
            Text("「\(track.displayTitle)」会从作品和播放列表移除。原文件和独立摘选会保留。")
        }
        .onChange(of: store.contentRevision) { _, _ in dragSession.invalidate(); reloadSections() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { dragSession.invalidate() } }
        .onDisappear { dragSession.invalidate() }
        .subtitleImportReceipt($subtitleReceipt)
        .alert(assetMessage != nil ? L10n.text("作品更新") : L10n.text("导入字幕"), isPresented: Binding(
            get: { assetMessage != nil || subtitleImportMessage != nil },
            set: { if !$0 { assetMessage = nil; subtitleImportMessage = nil } }
        )) {
            Button("好") { assetMessage = nil; subtitleImportMessage = nil }
        } message: {
            Text(assetMessage ?? subtitleImportMessage ?? "")
        }
        .porcelainSheet(isPresented: $showOrganizer) {
            TrackOrganizerSheet(work: currentWork, store: store, onChanged: reloadSections)
        }
        .task {
            reloadSections()
            #if DEBUG
            // 调试：`-newCategory` 直接弹出新建分组表单，方便验证
            if CommandLine.arguments.contains("-newCategory") {
                editorText = ""
                editorMode = .create
            }
            if CommandLine.arguments.contains("-organizer") {
                showOrganizer = true
            }
            #endif
        }
        .task(id: work.id) { await refreshAttachments() }
        .refreshable { await refreshAttachments() }
        .porcelainSurface()
        .preference(key: PorcelainTabBackdrop.self, value: AppTheme.usesCustomPalette)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showFavoritePicker = true } label: {
                Label(currentWork.favorite ? L10n.text("管理收藏") : L10n.text("收藏作品"), systemImage: currentWork.favorite ? "heart.fill" : "heart")
            }
            .tint(AppTheme.usesCustomPalette ? AppTheme.emphasisIcon : nil)
            .accessibilityIdentifier("workFavorite")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    fileImportKind = .media
                    showFileImporter = true
                } label: { Label("添加音轨或附件…", systemImage: "music.note.list") }
                .accessibilityIdentifier("addAudio")
                Button { showMetadataEditor = true } label: {
                    Label("编辑作品资料…", systemImage: "pencil")
                }
                Button { showScriptImporter = true } label: {
                    Label("导入作品台本…", systemImage: "doc.text")
                }
                .accessibilityIdentifier("importWorkScript")
                Button { showRelinkSheet = true } label: {
                    Label("重新关联文件夹…", systemImage: "link")
                }
                .accessibilityIdentifier("relinkWorkFolder")
                Divider()
                Button {
                    showOrganizer = true
                } label: {
                    Label(presentation == .personal ? L10n.text("整理分类与顺序…") : L10n.text("整理分组与顺序…"),
                          systemImage: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier("organizeTracks")
                if presentation == .collection {
                    Button {
                        editorText = ""
                        editorMode = .create
                    } label: {
                        Label("新建分组", systemImage: "folder.badge.plus")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("作品菜单")
            .accessibilityIdentifier("workOptions")
            .disabled(isImportingAsset)
        }
    }

    // MARK: - 顶部信息

    private var personalActions: some View {
        HStack(spacing: 12) {
            Button { showMetadataEditor = true } label: {
                Label("编辑资料", systemImage: "pencil").frame(maxWidth: .infinity)
            }.accessibilityIdentifier("personalInfoEditMetadata")
            Button { showScriptImporter = true } label: {
                Label("导入台本", systemImage: "doc.badge.plus").frame(maxWidth: .infinity)
            }.accessibilityIdentifier("personalInfoImportScript")
        }
        .buttonStyle(.bordered)
        .disabled(isImportingAsset)
    }

    private var personalContent: some View {
        let items = sections.flatMap(\.items)
        return VStack(alignment: .leading, spacing: 10) {
            Text("作品内容").font(.headline).foregroundStyle(AppTheme.headingInk(previous: AppTheme.ink))
            if items.isEmpty {
                Text("还没有音频、台本或附件，可从作品菜单添加文件。")
                    .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Group {
                            switch item {
                            case .track(let track):
                                trackRow(track: track, displayIndex: index + 1)
                                    .accessibilityIdentifier("workTrack-\(track.id)")
                            case .attachment(let record):
                                WorkAttachmentRowView(record: record, work: currentWork, store: store)
                                    .padding(.horizontal, 15)
                            }
                        }
                        .frame(minHeight: 61)
                        if index + 1 < items.count { Divider().overlay(AppTheme.painted(.clear, AppTheme.separator)).padding(.leading, 16) }
                    }
                }
                .background(AppTheme.groupedCard,
                            in: RoundedRectangle(cornerRadius: 13))
            }
        }
        .accessibilityIdentifier("personalWorkContent")
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverImageView(path: currentWork.resolvedCoverPath ?? currentWork.coverPath, cornerRadius: 10)
                .aspectRatio(4.0 / 3, contentMode: .fit)
                .frame(width: sizeClass == .regular ? 224 : (presentation == .collection ? 220 : 194))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)

            Text(currentWork.title)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(AppTheme.primaryText)
                .accessibilityIdentifier("workDetailTitle")
            if currentWork.libraryKind == .personal {
                if let creator = store.creator(id: currentWork.creatorID) {
                    NavigationLink {
                        CreatorProfileView(creatorID: creator.id, store: store)
                    } label: {
                        HStack(spacing: 8) {
                            CreatorAvatarView(path: store.creatorAvatarPath(creator), name: creator.name, size: 28)
                            Text(creator.name).font(.subheadline)
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                    }.accessibilityIdentifier("workCreator")
                } else {
                    Text("创作者待填写").font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                }
            } else {
                if let circle = currentWork.circleName, !circle.isEmpty {
                    Text(circle).font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                }
                if let voices = currentWork.seiyuuName, !voices.isEmpty {
                    Text(voices.replacingOccurrences(of: "、", with: "/"))
                        .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                }
            }
            Text(workDetails)
                .font(.caption).foregroundStyle(AppTheme.secondaryText)
                .accessibilityIdentifier("workDetailFacts")
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var workDetails: String {
        var facts = [String]()
        if let rj = currentWork.rjCode { facts.append(rj) }
        if currentWork.trackCount > 0 { facts.append(L10n.text("\(currentWork.trackCount) 首音轨")) }
        let videos = sections.flatMap(\.items).filter { item in
            if case .attachment(let file) = item { return file.attachment.kind == .video }
            return false
        }.count
        if videos > 0 { facts.append(L10n.text("\(videos) 个视频")) }
        if currentWork.durationForDisplayMS > 0 { facts.append(totalDurationText) }
        return facts.joined(separator: " · ")
    }

    private var contentSections: some View {
        ForEach(sections) { section in
            VStack(spacing: 0) {
                dropZone(.header(section.id)) {
                    sectionHeader(section.category, count: section.items.count)
                        .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                        .padding(.horizontal, 12).padding(.vertical, 0)
                }
                .onDrag { beginDrag(.group(section.id)) } preview: {
                    Text(section.category.localizedTitle).padding()
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("workGroup-\(section.id)")

                LazyVStack(spacing: 0) {
                    ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                        switch item {
                        case .track(let track):
                            dropZone(.item(section.id, item.id)) {
                                VStack(spacing: 0) {
                                    trackRow(track: track, displayIndex: index + 1)
                                    if index + 1 < section.items.count { Divider().overlay(AppTheme.painted(.clear, AppTheme.separator)).padding(.leading, 15) }
                                }
                            }
                            .onDrag { beginDrag(.item(item.id)) } preview: { Text(item.title).padding() }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("workTrack-\(track.id)")
                        case .attachment(let record):
                            dropZone(.item(section.id, item.id)) {
                                VStack(spacing: 0) {
                                    WorkAttachmentRowView(record: record, work: currentWork, store: store)
                                        .padding(.horizontal, 15).frame(minHeight: 61)
                                    if index + 1 < section.items.count { Divider().overlay(AppTheme.painted(.clear, AppTheme.separator)).padding(.leading, 15) }
                                }
                            }
                        }
                    }
                }
                .background(AppTheme.groupedCard,
                            in: RoundedRectangle(cornerRadius: 13))
                dropZone(.footer(section.id)) {
                    if section.items.isEmpty {
                        Text("空分组 · 可拖入音轨")
                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .background(AppTheme.groupedCard,
                                        in: RoundedRectangle(cornerRadius: 13))
                    } else {
                        Color.clear.frame(height: 16)
                    }
                }
            }
        }
    }

    private func beginDrag(_ content: WorkReorderPayload.Content) -> NSItemProvider {
        let snapshot = WorkReorderSnapshot(workID: work.id,
            sections: store.organizedSections(for: currentWork, includeEmpty: true))
        return dragSession.begin(WorkReorderPayload(workID: work.id, content: content), snapshot: snapshot)
    }

    private func dropZone<Content: View>(_ surface: WorkDropSurface,
                                         @ViewBuilder content: @escaping () -> Content) -> some View {
        WorkMediaDropZone(session: dragSession, surface: surface, save: { payload, destination, snapshot in
            try store.applyReorder(payload, in: currentWork, to: destination, expected: snapshot)
            reloadSections()
        }, onError: { assetMessage = $0 }, content: content)
    }

    private func sectionHeader(_ category: WorkCategory, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: category.isBuiltin
                  ? (TrackCategory(rawValue: category.key)?.iconName ?? "folder")
                  : "folder.fill")
                .font(.caption2)
            Text(category.localizedTitle)
            Text("\(count)").font(.caption2).foregroundStyle(AppTheme.tertiaryText)
            Spacer(minLength: 0)
            Menu {
                Button("重命名分组") { beginRename(category) }
                Button("整理分组与顺序…") { showOrganizer = true }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(AppTheme.secondary)
            .accessibilityLabel("\(category.localizedTitle)的分组操作")
            .accessibilityIdentifier("workGroupOptions-\(category.key)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityAction(named: L10n.text("重命名分组")) { beginRename(category) }
    }

    private func beginRename(_ category: WorkCategory) {
        editingCategoryKey = category.key
        editorText = category.title
        editorMode = .rename(original: category.title)
    }

    private func contextMenu(for track: TrackRecord) -> some View {
        Group {
            Button {
                subtitlePickerTrack = track
                fileImportKind = .subtitle
                showFileImporter = true
            } label: {
                Label("导入字幕文件…", systemImage: "square.and.arrow.down")
            }

            Menu {
                ForEach(allCategories) { candidate in
                    Button {
                        store.moveTracks([track.id], toCategory: candidate.key, in: work)
                        reloadSections()
                    } label: {
                        if candidate.key == track.effectiveCategoryKey {
                            Label(candidate.title, systemImage: "checkmark")
                        } else {
                            Text(candidate.title)
                        }
                    }
                }
                if track.categoryOverride != nil {
                    Divider()
                    Button {
                        store.moveTracks([track.id], toCategory: nil, in: work)
                        reloadSections()
                    } label: {
                        Label("恢复自动分组", systemImage: "arrow.uturn.backward")
                    }
                }
            } label: {
                Label("移到分组", systemImage: "folder")
            }

            Button {
                editorText = ""
                editorMode = .create
            } label: {
                Label("新建分组…", systemImage: "folder.badge.plus")
            }
            Button(role: .destructive) { pendingRemoval = track } label: {
                Label("移除音轨", systemImage: "trash")
            }
        }
    }

    private func trackRow(track: TrackRecord, displayIndex: Int) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(displayIndex)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.tertiaryText)
                    .frame(width: 22, alignment: .trailing)
    
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.displayTitle).font(.subheadline).lineLimit(2)
                    HStack(spacing: 5) {
                        Text(track.fileType.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                        if let ms = track.durationMS {
                            Text(format(ms)).font(.caption2).foregroundStyle(AppTheme.secondaryText)
                        }
                        if track.assetRelativePath != nil {
                            Text("单独添加").font(.system(size: 9)).foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { play(track) }
            Menu { contextMenu(for: track) } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(AppTheme.isPurple ? AppTheme.iconTint : AppTheme.secondary)
            .accessibilityLabel("\(track.displayTitle)的音轨操作")
            .accessibilityIdentifier("workTrackOptions-\(track.id)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("文件位置").font(.footnote).foregroundStyle(AppTheme.secondaryText)
                .padding(.horizontal, 16)
            Text(currentWork.folderPath.contains("/ImportedArchives/") ? L10n.text("App 内的 ZIP 副本") : URL(fileURLWithPath: currentWork.folderPath).lastPathComponent)
                .accessibilityIdentifier("workPathValue")
                .font(.caption.monospaced())
                .foregroundStyle(AppTheme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(AppTheme.groupedCard,
                            in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - 逻辑

    private func handleFileImport(_ result: Result<[URL], Error>) {
        // Do not flash the importing overlay or validate a subtitle target on cancel.
        if case .failure(let error) = result, (error as? CocoaError)?.code == .userCancelled {
            if fileImportKind == .subtitle { subtitlePickerTrack = nil }
            return
        }
        if fileImportKind == .subtitle { importSubtitleFile(result); return }
        Task {
            isImportingAsset = true
            defer { isImportingAsset = false }
            do {
                let urls = try result.get()
                guard !urls.isEmpty else { return }
                let count = try await store.addMediaFiles(urls, to: currentWork)
                assetMessage = L10n.text("已添加 \(count) 个文件。")
                reloadSections()
            } catch {
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError {
                    assetMessage = L10n.text("没有保存本次选择：\(error.localizedDescription)")
                }
            }
        }
    }

    private func refreshAttachments() async {
        do { try await store.refreshAttachments(for: currentWork) }
        catch is CancellationError { return }
        catch { assetMessage = L10n.text("作品目录暂时无法刷新：\(error.localizedDescription)") }
        reloadSections()
    }

    /// 给指定曲目导入一个字幕文件
    private func importSubtitleFile(_ result: Result<[URL], Error>) {
        guard let track = subtitlePickerTrack else { return }
        subtitlePickerTrack = nil

        guard let repository = store.subtitleRepository else {
            subtitleImportMessage = L10n.text("字幕存储未就绪")
            return
        }

        switch result {
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled { return }
            subtitleImportMessage = L10n.text("选择文件失败：\(error.localizedDescription)")
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url),
                  let text = SubtitleTextDecoder.decode(data: data) else {
                subtitleImportMessage = L10n.text("读不出这个文件（可能是加密或损坏）")
                return
            }

            let format = SubtitleFormat.from(fileExtension: url.pathExtension)
            let parsed = SubtitleParser.parse(text, formatHint: format)
            guard !parsed.cues.isEmpty else {
                var hint = L10n.text("这个文件里没有解析出字幕（\(text.count) 字）")
                if !parsed.warnings.isEmpty {
                    hint += "\n" + parsed.warnings.prefix(2).joined(separator: "\n")
                }
                subtitleImportMessage = hint
                return
            }

            do {
                _ = try repository.createTrack(
                    trackID: track.id,
                    kind: .manual,
                    language: url.lastPathComponent.lowercased().contains("zh") ? "zh" : nil,
                    label: url.lastPathComponent,
                    cues: parsed.cues,
                    note: "手动导入",
                    activate: true
                )
                if subtitles.loadedTrackID == track.id { subtitles.forceReload() }
                subtitleReceipt = SubtitleImportReceipt(detail: L10n.text("\(parsed.cues.count) 句 · \(url.lastPathComponent)"))
            } catch {
                subtitleImportMessage = L10n.text("保存失败：\(error.localizedDescription)")
            }
        }
    }

    private func reloadSections() {
        refreshedWork = try? store.work(id: work.id)
        sections = store.organizedSections(for: currentWork)
        allCategories = store.categories(for: work)
    }

    private func commitEditor(mode: CategoryEditorSheet.Mode, title: String) {
        switch mode {
        case .create:
            store.addCategory(for: work, title: title)
        case .rename:
            if let key = editingCategoryKey {
                do { try store.renameCategoryTitle(for: currentWork, key: key, title: title) }
                catch { assetMessage = error.localizedDescription }
            }
        }
        editorMode = nil
        reloadSections()
    }

    private func play(_ track: TrackRecord) {
        let items = store.queueItems(for: currentWork)
        guard let index = items.firstIndex(where: { $0.trackID == track.id }) else { return }
        player.play(items: items, startingAt: index)
        if let error = player.errorMessage { assetMessage = L10n.text("无法播放：\(error)") }
    }

    private var totalDurationText: String {
        let minutes = Int((Double(currentWork.durationForDisplayMS) / 1000).rounded()) / 60
        if minutes >= 60 { return L10n.text("\(minutes / 60) 小时 \(minutes % 60) 分") }
        if minutes > 0 { return L10n.text("\(minutes) 分") }
        let seconds = Int((Double(currentWork.durationForDisplayMS) / 1000).rounded())
        return seconds > 0 ? L10n.text("\(seconds) 秒") : "—"
    }

    private func format(_ ms: Int) -> String {
        let totalSeconds = Int((Double(ms) / 1000).rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - 让 Mode 可以直接用于 sheet(item:)

extension CategoryEditorSheet.Mode: Identifiable {
    var id: String {
        switch self {
        case .create: return "create"
        case .rename(let original): return "rename:\(original)"
        }
    }

    var originalTitle: String {
        switch self {
        case .create: return ""
        case .rename(let original): return original
        }
    }
}
