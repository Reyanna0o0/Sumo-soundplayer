import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Edits one creator. New image files belong to this draft until Save succeeds.
struct CreatorEditorSheet: View {
    let creator: CreatorRecord?
    @ObservedObject var store: LibraryStore
    let onSaved: (Int64) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var note: String
    @State private var avatar: String?
    @State private var coverMode: CreatorCoverMode
    @State private var cover: String?
    @State private var avatarPhoto: PhotosPickerItem?
    @State private var coverPhoto: PhotosPickerItem?
    @State private var fileTarget: ImageTarget = .avatar
    @State private var showFilePicker = false
    @State private var loading = false
    @State private var message: String?
    @State private var draftAssets = Set<String>()
    @State private var imageTask: Task<Void, Never>?
    @StateObject private var callDraft: CallProfileDraft
    @State private var callProfileLoadError: String?

    private enum ImageTarget: Equatable { case avatar, cover }

    init(creator: CreatorRecord?, store: LibraryStore, onSaved: @escaping (Int64) -> Void = { _ in }) {
        self.creator = creator
        self.store = store
        self.onSaved = onSaved
        _name = State(initialValue: creator?.name ?? "")
        _note = State(initialValue: creator?.note ?? "")
        _avatar = State(initialValue: creator?.avatarAssetPath)
        _coverMode = State(initialValue: creator?.coverMode ?? .none)
        _cover = State(initialValue: creator?.coverAssetPath)
        let profile: CallProfile
        let loadError: String?
        do {
            profile = try creator.map { try store.callProfile(ownerKind: .creator, id: $0.id) } ?? .defaults(for: .creator)
            loadError = nil
        } catch { profile = .defaults(for: .creator); loadError = error.localizedDescription }
        _callDraft = StateObject(wrappedValue: CallProfileDraft(profile: profile))
        _callProfileLoadError = State(initialValue: loadError)
    }

    var body: some View {
        NavigationStack {
            AppForm {
                Section("头像") {
                    HStack { Spacer(); CreatorAvatarView(path: avatar.flatMap(WorkAssetImporter.path), name: name, size: 96); Spacer() }
                    PhotosPicker(selection: $avatarPhoto, matching: .images) {
                        Label("从照片选择头像", systemImage: "photo")
                    }.disabled(loading)
                    Button("从文件选择头像", systemImage: "folder") { chooseFile(.avatar) }.disabled(loading)
                        .accessibilityIdentifier("creatorAvatarFromFiles")
                    if avatar != nil {
                        Button("移除头像", role: .destructive) { replaceDraft(nil, for: .avatar) }.disabled(loading)
                    }
                }
                Section("创作者名字") {
                    TextField("名字", text: $name).accessibilityIdentifier("creatorName")
                }
                Section("简介") {
                    TextField("简介（选填）", text: $note, axis: .vertical).lineLimit(4...10)
                        .accessibilityIdentifier("creatorNote")
                }
                if let callProfileLoadError {
                    Section { Text(callProfileLoadError).foregroundStyle(.red) }
                } else {
                    CallProfileFields(draft: callDraft, ownerKind: .creator, inheritedAvatarURL: store.callAssetURL(avatar))
                }
                Section {
                    Picker("作品封面", selection: $coverMode) {
                        Text("无封面").tag(CreatorCoverMode.none)
                        Text("使用头像").tag(CreatorCoverMode.avatar)
                        Text("自选图片").tag(CreatorCoverMode.image)
                    }.accessibilityIdentifier("creatorCoverMode")
                    if coverMode == .image {
                        if let cover, let path = WorkAssetImporter.path(for: cover) {
                            CoverImageView(path: path, contentMode: .fit).frame(maxHeight: 170)
                        }
                        PhotosPicker(selection: $coverPhoto, matching: .images) {
                            Label("从照片选择封面", systemImage: "photo")
                        }.disabled(loading)
                        Button("从文件选择封面", systemImage: "folder") { chooseFile(.cover) }.disabled(loading)
                            .accessibilityIdentifier("creatorCoverFromFiles")
                        if cover == nil { Text("请选择一张封面图片。").font(.caption).foregroundStyle(AppTheme.secondaryText) }
                    }
                } header: { Text("封面") } footer: {
                    Text("封面设置应用到这位创作者的全部作品。无封面时，播放器使用头像；作品列表仍显示头像。")
                }
                if loading { ProgressView("正在读取图片…") }
                if let message { Text(message).foregroundStyle(.red).font(.footnote) }
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 48)
            .appNavigationColors().navigationTitle(creator == nil ? L10n.text("新建创作者") : L10n.text("编辑创作者"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(loading || callDraft.isLoading || callProfileLoadError != nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (coverMode == .image && cover == nil))
                        .accessibilityIdentifier("saveCreator")
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.image]) { result in
                switch result {
                case .success(let url): loadFile(url, target: fileTarget)
                case .failure(let error):
                    if (error as? CocoaError)?.code != .userCancelled { message = error.localizedDescription }
                }
            }
            .onChange(of: avatarPhoto) { _, item in if let item { loadPhoto(item, target: .avatar) } }
            .onChange(of: coverPhoto) { _, item in if let item { loadPhoto(item, target: .cover) } }
            .onDisappear {
                imageTask?.cancel()
                for relative in draftAssets { WorkAssetImporter.remove(relative) }
                draftAssets.removeAll()
                callDraft.cancel()
            }
        }
    }

    private func chooseFile(_ target: ImageTarget) { fileTarget = target; showFilePicker = true }

    private func loadFile(_ url: URL, target: ImageTarget) {
        imageTask?.cancel()
        loading = true; message = nil
        imageTask = Task {
            defer { loading = false }
            do {
                let relative = try await Task.detached(priority: .userInitiated) {
                    try WorkAssetImporter.copyCover(from: url)
                }.value
                if Task.isCancelled { WorkAssetImporter.remove(relative); return }
                replaceDraft(relative, for: target)
            } catch { if !Task.isCancelled { message = L10n.text("无法读取图片：\(error.localizedDescription)") } }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem, target: ImageTarget) {
        imageTask?.cancel()
        loading = true; message = nil
        imageTask = Task {
            defer { loading = false; avatarPhoto = nil; coverPhoto = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw WorkAssetImportError.unreadableImage }
                try Task.checkCancellation()
                let relative = try await Task.detached(priority: .userInitiated) {
                    try WorkAssetImporter.copyCover(data: data)
                }.value
                if Task.isCancelled { WorkAssetImporter.remove(relative); return }
                replaceDraft(relative, for: target)
            } catch { if !Task.isCancelled { message = L10n.text("无法读取图片：\(error.localizedDescription)") } }
        }
    }

    private func replaceDraft(_ relative: String?, for target: ImageTarget) {
        let old = target == .avatar ? avatar : cover
        if target == .avatar { avatar = relative } else { cover = relative }
        if let old, draftAssets.remove(old) != nil { WorkAssetImporter.remove(old) }
        if let relative { draftAssets.insert(relative) }
    }

    private func save() {
        do {
            var value = creator ?? CreatorRecord(name: name)
            value.name = name
            value.note = note
            value.avatarAssetPath = avatar
            value.coverMode = coverMode
            value.coverAssetPath = cover
            let id = try store.saveCreator(value, callProfile: callDraft.profile)
            // The saved creator now owns these images; cancelling never reaches here.
            draftAssets.removeAll()
            _ = callDraft.commit()
            onSaved(id)
            dismiss()
        } catch { message = L10n.text("没有保存本次修改：\(error.localizedDescription)") }
    }
}
