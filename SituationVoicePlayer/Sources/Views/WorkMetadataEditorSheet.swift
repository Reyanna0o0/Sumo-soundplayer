import SwiftUI
import UniformTypeIdentifiers

struct WorkMetadataEditorSheet: View {
    let work: WorkRecord
    @ObservedObject var store: LibraryStore
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var title: String
    @State private var rjCode: String
    @State private var circleName: String
    @State private var actors: [ActorName]
    @State private var errorMessage: String?
    @State private var cover: WorkCoverUpdate = .unchanged
    @State private var playerCoverMode: PlayerCoverMode
    @State private var cropInput: CoverCropInput?
    @StateObject private var mediaPicker = MediaPickerPresenter()
    @State private var isLoadingCover = false
    @State private var coverTask: Task<Void, Never>?
    @State private var creatorID: Int64?
    @State private var showCreatorEditor = false
    @StateObject private var callDraft: CallProfileDraft
    @State private var callProfileLoadError: String?
    @State private var showCoverActions = false
    @State private var pendingCoverSource: CoverSource?

    private enum CoverSource {
        case photos
        case files
        case existing(String)
    }

    private struct ActorName: Identifiable {
        let id = UUID()
        var name: String
    }

    init(work: WorkRecord, store: LibraryStore, onSaved: @escaping () -> Void = {}) {
        self.work = work
        self.store = store
        self.onSaved = onSaved
        _title = State(initialValue: work.title)
        _playerCoverMode = State(initialValue: work.playerCoverMode)
        _rjCode = State(initialValue: work.rjCode ?? "")
        _creatorID = State(initialValue: work.creatorID)
        _circleName = State(initialValue: work.circleName ?? "")
        _actors = State(initialValue: (work.seiyuuNames.isEmpty ? [""] : work.seiyuuNames).map { ActorName(name: $0) })
        let initial: CallProfile
        let loadError: String?
        do { initial = try store.callProfile(ownerKind: .work, id: work.id); loadError = nil }
        catch { initial = .defaults(for: .work); loadError = error.localizedDescription }
        _callDraft = StateObject(wrappedValue: CallProfileDraft(profile: initial))
        _callProfileLoadError = State(initialValue: loadError)
    }

    var body: some View {
        NavigationStack {
            AppForm {
                Section {
                    TextField("作品名称", text: $title, axis: .vertical)
                        .accessibilityIdentifier("metadataTitle")
                        .listRowInsets(publicationRowInsets)
                } header: { publicationHeader(L10n.text("作品名称")) }
                if work.libraryKind == .personal {
                    Section { playerCoverModePicker } header: { publicationHeader(L10n.text("封面")) }
                    callProfileSection
                    personalCreatorSection
                } else {
                    coverSection
                        .listSectionSpacing(12)
                    Section { playerCoverModePicker }
                    Section {
                        TextField("社团名称", text: $circleName)
                            .accessibilityIdentifier("metadataCircle")
                            .listRowInsets(publicationRowInsets)
                    } header: { publicationHeader(L10n.text("发布社团")) }
                    Section {
                        ForEach($actors) { $actor in
                            HStack {
                                TextField("声优名称", text: $actor.name)
                                    .accessibilityIdentifier("metadataActor-\(actors.firstIndex { $0.id == actor.id } ?? 0)")
                                Button(role: .destructive) {
                                    actors.removeAll { $0.id == actor.id }
                                } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("移除声优 \(actor.name)")
                            }
                            .listRowInsets(publicationRowInsets)
                        }
                        Button { actors.append(ActorName(name: "")) } label: {
                            Label("添加一位声优", systemImage: "plus.circle")
                        }
                        .accessibilityIdentifier("addActor")
                        .listRowInsets(publicationRowInsets)
                    } header: { publicationHeader(L10n.text("声优")) } footer: {
                        Text("每位声优单独填写一行。名称、封面和其他资料会在点保存后一起生效，重新扫描也会保留。")
                    }
                    Section {
                        TextField("例如 RJ344468 或 BJ123456", text: $rjCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("metadataRJ")
                            .listRowInsets(publicationRowInsets)
                    } header: { publicationHeader(L10n.text("作品编号（选填）")) }
                    callProfileSection
                }
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 48)
            .appNavigationColors().navigationTitle(L10n.text("编辑作品资料"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                    .disabled(isLoadingCover || callDraft.isLoading || callProfileLoadError != nil)
                    .accessibilityIdentifier("saveMetadata")
                }
            }
            .sheet(item: $cropInput) { input in
                CoverCropSheet(input: input, onUse: acceptCoverDraft)
            }
            .sheet(isPresented: $showCreatorEditor) {
                CreatorEditorSheet(creator: nil, store: store) { creatorID = $0 }
            }
            .alert("请检查作品资料", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("确定") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onDisappear {
                coverTask?.cancel()
                discardCoverDraft()
                callDraft.cancel()
            }
        }
        .mediaPickerPresentation(mediaPicker)
    }

    private var publicationRowInsets: EdgeInsets {
        EdgeInsets(top: 12, leading: 15, bottom: 12, trailing: 15)
    }

    private func publicationHeader(_ title: String) -> some View {
        Text(title).offset(x: -8)
    }

    @ViewBuilder private var callProfileSection: some View {
        if let callProfileLoadError {
            Section { Text(callProfileLoadError).foregroundStyle(.red) }
        } else {
            CallProfileFields(draft: callDraft, ownerKind: .work,
                inheritsWorkCover: work.libraryKind == .collection,
                inheritedAvatarURL: inheritedCallAppearance?.avatarURL,
                inheritedBackgroundURL: inheritedCallAppearance?.backgroundURL,
                inheritedBackgroundKind: inheritedCallAppearance?.backgroundKind ?? .image,
                inheritedAvatarFraming: inheritedCallAppearance?.avatarFraming,
                inheritedBackgroundFraming: inheritedCallAppearance?.backgroundFraming)
        }
    }

    private var inheritedCallAppearance: ResolvedCallAppearance? {
        if work.libraryKind == .collection {
            let coverURL = previewCoverPath.map { WorkAssetImporter.originalImageForCropping(at: $0) }
            return ResolvedCallAppearance(name: title, avatarURL: coverURL, avatarFraming: callDraft.profile.avatarFraming,
                backgroundURL: coverURL, backgroundKind: .image, backgroundFraming: callDraft.profile.backgroundFraming,
                prefersWorkVideo: callDraft.profile.prefersWorkVideo)
        }
        guard let id = creatorID, let author = store.creator(id: id) else { return nil }
        return try? store.resolvedCreatorCallAppearance(author)
    }

    private var personalCreatorSection: some View {
        Section {
            Picker("创作者", selection: $creatorID) {
                Text("待填写").tag(Optional<Int64>.none)
                ForEach(store.creators) { creator in
                    Text(creator.name).tag(Optional(creator.id))
                }
            }.accessibilityIdentifier("metadataCreator")
            Button("新建创作者", systemImage: "person.badge.plus") { showCreatorEditor = true }
                .accessibilityIdentifier("metadataNewCreator")
        } header: { Text("作品归属") } footer: {
            Text("头像和封面统一在创作者资料中设置。修改作品归属会保留音轨、字幕、分类和阅读位置。")
        }
    }

    private var coverSection: some View {
        Section {
            HStack {
                Spacer()
                CoverImageView(path: previewCoverPath, cornerRadius: 10, contentMode: .fit)
                    .frame(width: 220, height: 165)
                Spacer()
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("封面预览")
            .accessibilityIdentifier("metadataCoverPreview")
            .contentShape(Rectangle())
            .onLongPressGesture { showCoverActions = true }
            .accessibilityAction(named: L10n.text("封面操作")) { showCoverActions = true }
            .popover(isPresented: $showCoverActions, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 18) { coverActions }
                    .padding(20)
                    .presentationCompactAdaptation(.popover)
                    .porcelainCoverPopover()
                    .onDisappear(perform: openPendingCoverSource)
            }
            if isLoadingCover {
                ProgressView("正在读取封面…")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } header: { publicationHeader(L10n.text("封面")) } footer: {
            Text("长按封面选择图片或调整裁剪；取消编辑会保留现有封面。")
                .accessibilityIdentifier("metadataCoverHint")
        }
    }

    private var playerCoverModePicker: some View {
        Picker("播放器封面", selection: $playerCoverMode) {
            Text("原图比例").tag(PlayerCoverMode.original)
            Text("4:3 完整显示（留边）").tag(PlayerCoverMode.fit4x3)
            Text("4:3 居中裁切铺满").tag(PlayerCoverMode.fill4x3)
        }
        .listRowInsets(publicationRowInsets)
        .listRowBackground(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(AppTheme.groupedCard))
        .accessibilityIdentifier("metadataPlayerCoverMode")
    }

    @ViewBuilder private var coverActions: some View {
        Button { chooseCoverSource(.photos) } label: {
            coverActionLabel(L10n.text("从照片选择"), symbol: "photo.on.rectangle")
        }
        .disabled(isLoadingCover)
        Button { chooseCoverSource(.files) } label: {
            coverActionLabel(L10n.text("从文件选择"), symbol: "folder")
        }
        .disabled(isLoadingCover)
        .accessibilityIdentifier("coverFromFiles")
        if let path = previewCoverPath {
            Button { chooseCoverSource(.existing(path)) } label: {
                coverActionLabel(L10n.text("调整裁剪"), symbol: "crop")
            }
            .disabled(isLoadingCover).accessibilityIdentifier("adjustCrop")
        }
        if canRestoreCover {
            Button {
                showCoverActions = false
                discardCoverDraft()
                cover = .restoreOriginal
                errorMessage = nil
            } label: { coverActionLabel(L10n.text("恢复原封面"), symbol: "arrow.uturn.backward") }
            .disabled(isLoadingCover).accessibilityIdentifier("restoreOriginalCover")
        }
    }

    @ViewBuilder
    private func coverActionLabel(_ title: String, symbol: String) -> some View {
        if AppTheme.usesChoicePanels(in: colorScheme) {
            Label {
                Text(title).foregroundStyle(PorcelainChoicePanelColors.ink)
            } icon: {
                Image(systemName: symbol).foregroundStyle(AppTheme.iconTint)
            }
        } else {
            Label(title, systemImage: symbol)
        }
    }

    private func chooseCoverSource(_ source: CoverSource) {
        pendingCoverSource = source
        showCoverActions = false
    }

    // The editor owns the system pickers. Open one after its menu has disappeared.
    private func openPendingCoverSource() {
        guard let source = pendingCoverSource else { return }
        pendingCoverSource = nil
        switch source {
        case .photos: mediaPicker.present(.photo(loadPhoto))
        case .files:
            mediaPicker.present(.file(types: [.image]) { url in
                prepareCover { try WorkAssetImporter.copyCover(from: url) }
            })
        case .existing(let path):
            let original = WorkAssetImporter.originalImageForCropping(at: path)
            prepareCover { try WorkAssetImporter.copyCover(from: original) }
        }
    }

    private var previewCoverPath: String? {
        switch cover {
        case .unchanged: return work.resolvedCoverPath ?? work.coverPath
        case .replace(let relative): return WorkAssetImporter.path(for: relative)
        case .restoreOriginal: return store.originalCoverPath(for: work)
        }
    }

    private var canRestoreCover: Bool {
        switch cover {
        case .unchanged: return work.coverAssetPath != nil
        case .replace: return true
        case .restoreOriginal: return false
        }
    }

    private func prepareCover(_ copy: @escaping @Sendable () throws -> String) {
        coverTask?.cancel()
        isLoadingCover = true
        errorMessage = nil
        coverTask = Task {
            defer { isLoadingCover = false }
            do {
                let relative = try await Task.detached(priority: .userInitiated, operation: copy).value
                beginCrop(relative)
            } catch {
                if !Task.isCancelled { errorMessage = L10n.text("无法读取封面：\(error.localizedDescription)") }
            }
        }
    }

    private func loadPhoto(_ photo: LibraryPhotoSelection) {
        coverTask?.cancel()
        isLoadingCover = true
        errorMessage = nil
        coverTask = Task {
            defer { isLoadingCover = false }
            do {
                let data = try await photo.loadData()
                try Task.checkCancellation()
                let relative = try await Task.detached(priority: .userInitiated) {
                    try WorkAssetImporter.copyCover(data: data)
                }.value
                beginCrop(relative)
            } catch {
                if !Task.isCancelled { errorMessage = L10n.text("无法读取封面：\(error.localizedDescription)") }
            }
        }
    }

    private func beginCrop(_ relative: String) {
        guard !Task.isCancelled else { WorkAssetImporter.remove(relative); return }
        cropInput = CoverCropInput(relativePath: relative)
    }

    private func acceptCoverDraft(_ relative: String) {
        guard !Task.isCancelled else { WorkAssetImporter.remove(relative); return }
        discardCoverDraft()
        cover = .replace(assetRelativePath: relative)
    }

    private func discardCoverDraft() {
        if case .replace(let relative) = cover { WorkAssetImporter.remove(relative) }
        cover = .unchanged
    }

    private func save() {
        do {
            if work.libraryKind == .personal {
                try store.savePersonalMetadata(for: work, title: title, creatorID: creatorID,
                                               callProfile: callDraft.profile, playerCoverMode: playerCoverMode)
            } else {
                try store.saveMetadata(for: work, title: title, rjCode: rjCode, circleName: circleName,
                                       seiyuuNames: actors.map(\.name), cover: cover,
                                       callProfile: callDraft.profile, playerCoverMode: playerCoverMode)
            }
            // 已交给媒体库管理，关闭表单时不再清理这张图片。
            cover = .unchanged
            _ = callDraft.commit()
            onSaved()
            dismiss()
        } catch { errorMessage = L10n.text("没有保存本次修改：\(error.localizedDescription)") }
    }
}
