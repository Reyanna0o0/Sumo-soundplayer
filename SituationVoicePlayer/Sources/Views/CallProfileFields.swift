import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Combine

enum CallProfileAssetTarget { case avatar, background }

/// Only assets created during this edit belong to the draft; saved/original files are never removed here.
@MainActor
final class CallProfileDraft: ObservableObject {
    @Published var profile: CallProfile
    @Published private(set) var isLoading = false
    @Published var error: String?
    private(set) var draftAssets = Set<String>()
    private var importTask: Task<Void, Never>?
    private var generation = UUID()

    init(profile: CallProfile) { self.profile = profile }

    func importImage(from url: URL, target: CallProfileAssetTarget) {
        beginImport(target: target, kind: .image) {
            try await Task.detached(priority: .userInitiated) {
                try WorkAssetImporter.copyCover(from: url)
            }.value
        }
    }

    func importPhoto(_ item: PhotosPickerItem, target: CallProfileAssetTarget) {
        beginImport(target: target, kind: .image) {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw WorkAssetImportError.unreadableImage
            }
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try WorkAssetImporter.copyCover(data: data)
            }.value
        }
    }

    func importVideo(from url: URL) {
        beginImport(target: .background, kind: .video) {
            try await WorkAssetImporter.copyCallBackgroundVideo(from: url)
        }
    }

    private func beginImport(target: CallProfileAssetTarget, kind: CallBackgroundKind,
                             operation: @escaping () async throws -> String) {
        importTask?.cancel()
        generation = UUID()
        let expected = generation
        isLoading = true; error = nil
        importTask = Task {
            defer {
                if generation == expected { isLoading = false; importTask = nil }
            }
            do {
                let path = try await operation()
                guard !Task.isCancelled, generation == expected else {
                    WorkAssetImporter.remove(path); return
                }
                draftAssets.insert(path)
                if target == .avatar {
                    profile.avatarAssetPath = path
                    profile.avatarMode = .custom
                    profile.avatarFraming = CallFraming()
                } else {
                    profile.backgroundAssetPath = path
                    profile.backgroundKind = kind
                    profile.backgroundMode = .custom
                    profile.backgroundFraming = CallFraming()
                }
                removeUnreferencedDraftAssets()
            } catch {
                guard !Task.isCancelled, generation == expected else { return }
                self.error = L10n.text("没有更换显示文件：\(error.localizedDescription) 原有设置已保留。")
            }
        }
    }

    func cancel() {
        generation = UUID()
        importTask?.cancel(); importTask = nil; isLoading = false
        for path in draftAssets { WorkAssetImporter.remove(path) }
        draftAssets.removeAll()
    }

    /// Call only after persistence succeeds. The saved profile now owns the referenced new assets.
    @discardableResult func commit() -> CallProfile {
        generation = UUID()
        importTask?.cancel(); importTask = nil; isLoading = false
        removeUnreferencedDraftAssets()
        draftAssets.removeAll()
        return profile
    }

    private func removeUnreferencedDraftAssets() {
        let referenced = Set([profile.avatarAssetPath, profile.backgroundAssetPath].compactMap { $0 })
        for path in draftAssets.subtracting(referenced) {
            WorkAssetImporter.remove(path); draftAssets.remove(path)
        }
    }
}

/// Form sections only: the embedding editor controls loading, persistence and asset ownership.
struct CallProfileFields: View {
    @ObservedObject var draft: CallProfileDraft
    let ownerKind: CallProfileOwnerKind
    var inheritsWorkCover = false
    var inheritedAvatarURL: URL?
    var inheritedBackgroundURL: URL?
    var inheritedBackgroundKind: CallBackgroundKind = .image
    var inheritedAvatarFraming: CallFraming?
    var inheritedBackgroundFraming: CallFraming?
    @State private var avatarPhoto: PhotosPickerItem?
    @State private var backgroundPhoto: PhotosPickerItem?
    @State private var fileTarget: CallProfileAssetTarget?
    @State private var framingTarget: FramingTarget?

    private enum FramingTarget: String, Identifiable {
        case avatar, background
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if ownerKind == .work {
                Section("通话角色") {
                    TextField("角色名（选填）", text: $draft.profile.roleName)
                        .accessibilityIdentifier("callRoleName")
                }
            }
            avatarSection
            if ownerKind != .localUser { backgroundSection }
            if draft.isLoading { ProgressView("正在复制显示文件…") }
            if let error = draft.error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
    }

    private var avatarSectionHeader: some View {
        Text(ownerKind == .localUser ? L10n.text("我的头像") : L10n.text("通话头像"))
    }

    private var avatarSection: some View {
        Section {
            if ownerKind != .localUser {
                Picker("显示头像", selection: $draft.profile.avatarMode) {
                    Text(inheritsWorkCover ? L10n.text("沿用作品封面") : (ownerKind == .work ? L10n.text("沿用作者头像") : L10n.text("沿用已有头像"))).tag(CallAvatarMode.inherit)
                    Text("自选图片").tag(CallAvatarMode.custom)
                    Text("无头像").tag(CallAvatarMode.none)
                }.accessibilityIdentifier("callAvatarMode")
            }
            if draft.profile.avatarMode != .none || ownerKind == .localUser {
                if avatarURL != nil || draft.profile.avatarMode == .custom {
                    CallFramingCanvas(url: avatarURL, framing: .constant(avatarPreviewFraming),
                                      allowsBlur: ownerKind != .localUser, isInteractive: false,
                                      isPreviewActive: framingTarget == nil)
                        .frame(width: ownerKind == .localUser ? 150 : 160,
                               height: ownerKind == .localUser ? 200 : 160)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                if draft.profile.avatarMode == .custom || ownerKind == .localUser {
                    PhotosPicker(selection: $avatarPhoto, matching: .images) {
                        Label("从照片选择图片", systemImage: "photo")
                    }.disabled(draft.isLoading)
                    .onChange(of: avatarPhoto) { _, item in
                        if let item { draft.importPhoto(item, target: .avatar); avatarPhoto = nil }
                    }
                    Button("从文件选择图片", systemImage: "folder") { chooseFile(.avatar) }
                        .disabled(draft.isLoading).accessibilityIdentifier("callAvatarFromFiles")
                        .fileImporter(isPresented: filePresentation(for: .avatar), allowedContentTypes: fileTypes(for: .avatar)) {
                            handleFileImport($0, target: .avatar)
                        }
                }
                if avatarURL != nil && !(ownerKind == .work && !inheritsWorkCover && draft.profile.avatarMode == .inherit) {
                    Button("放大预览与调整", systemImage: "crop.rotate") { framingTarget = .avatar }
                        .disabled(draft.isLoading).accessibilityIdentifier("callAvatarFraming")
                        .fullScreenCover(isPresented: framingPresentation(for: .avatar)) { framingSheet(for: .avatar) }
                }
            }
            if ownerKind == .localUser && draft.profile.avatarMode != .none {
                Button("移除显示图片", role: .destructive) { draft.profile.avatarMode = .none }
                    .disabled(draft.isLoading)
            }
        } header: { avatarSectionHeader }
        footer: {
            Text(ownerKind == .localUser ? L10n.text("按通话中的头像小窗比例预览；可缩小图片并保留黑边。") : L10n.text("取景只影响通话显示，不改写作者头像或作品封面。"))
        }
    }

    private var backgroundSection: some View {
        Section {
            Picker("背景", selection: $draft.profile.backgroundMode) {
                if ownerKind == .work { Text(inheritsWorkCover ? L10n.text("沿用作品封面") : L10n.text("沿用作者背景")).tag(CallBackgroundMode.inherit) }
                Text("无背景（黑底）").tag(CallBackgroundMode.none)
                if ownerKind == .creator { Text("使用头像").tag(CallBackgroundMode.avatar) }
                Text("自选图片或视频").tag(CallBackgroundMode.custom)
            }.accessibilityIdentifier("callBackgroundMode")
            if draft.profile.backgroundMode != .none {
                if backgroundURL != nil || draft.profile.backgroundMode == .custom {
                    CallFramingPreview(url: backgroundURL, kind: backgroundKind,
                        framing: .constant(backgroundPreviewFraming), previewKind: .background,
                        isInteractive: false, isPreviewActive: framingTarget == nil)
                        .frame(maxWidth: 170).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                if draft.profile.backgroundMode == .custom {
                    PhotosPicker(selection: $backgroundPhoto, matching: .images) {
                        Label("从照片选择背景图片", systemImage: "photo")
                    }.disabled(draft.isLoading)
                    .onChange(of: backgroundPhoto) { _, item in
                        if let item { draft.importPhoto(item, target: .background); backgroundPhoto = nil }
                    }
                    Button("从文件选择图片或视频", systemImage: "folder") { chooseFile(.background) }
                        .disabled(draft.isLoading).accessibilityIdentifier("callBackgroundFromFiles")
                        .fileImporter(isPresented: filePresentation(for: .background), allowedContentTypes: fileTypes(for: .background)) {
                            handleFileImport($0, target: .background)
                        }
                }
                if backgroundURL != nil && (draft.profile.backgroundMode != .inherit || inheritsWorkCover) {
                    if backgroundKind == .image {
                        Toggle("空间效果 · 增强", isOn: Binding(
                            get: { draft.profile.backgroundFraming.spatialEffectEnabled == true },
                            set: { draft.profile.backgroundFraming.spatialEffectEnabled = $0 }))
                            .disabled(draft.isLoading).accessibilityIdentifier("callBackgroundSpatialToggle")
                        Text("轻晃手机查看图片层次。首次在本机生成，略微放大后保留边缘过渡；关闭恢复原取景。")
                            .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                    }
                    Button("放大预览与调整背景", systemImage: "crop.rotate") { framingTarget = .background }
                        .disabled(draft.isLoading).accessibilityIdentifier("callBackgroundFraming")
                        .fullScreenCover(isPresented: framingPresentation(for: .background)) { framingSheet(for: .background) }
                }
            }
            if ownerKind == .work {
                Toggle("优先使用作品视频画面", isOn: $draft.profile.prefersWorkVideo)
                    .accessibilityIdentifier("callPreferWorkVideo")
            }
        } header: { Text("通话背景") } footer: {
            Text("视频背景仅静音循环显示。头像与背景分别保存取景；无背景显示黑底，不沿用其他图片。")
        }
    }

    private var avatarURL: URL? {
        switch draft.profile.avatarMode {
        case .inherit: return inheritedAvatarURL
        case .custom: return assetURL(draft.profile.avatarAssetPath)
        case .none: return nil
        }
    }

    private var backgroundURL: URL? {
        switch draft.profile.backgroundMode {
        case .inherit: return inheritedBackgroundURL
        case .custom: return assetURL(draft.profile.backgroundAssetPath)
        case .avatar: return avatarURL
        case .none: return nil
        }
    }

    private var backgroundKind: CallBackgroundKind {
        if draft.profile.backgroundMode == .inherit { return inheritedBackgroundKind }
        return draft.profile.backgroundMode == .custom ? draft.profile.backgroundKind : .image
    }

    private var avatarPreviewFraming: CallFraming {
        if ownerKind == .work && !inheritsWorkCover && draft.profile.avatarMode == .inherit { return inheritedAvatarFraming ?? CallFraming() }
        return draft.profile.avatarFraming
    }

    private var backgroundPreviewFraming: CallFraming {
        if draft.profile.backgroundMode == .inherit && !inheritsWorkCover { return inheritedBackgroundFraming ?? CallFraming() }
        return draft.profile.backgroundFraming
    }

    private func assetURL(_ relative: String?) -> URL? {
        relative.flatMap(WorkAssetImporter.path).map { URL(fileURLWithPath: $0) }
    }

    // Each lazy Form row owns its own presentation anchor. An off-screen header
    // must not be required to stay alive for a visible background button to work.
    private func framingPresentation(for target: FramingTarget) -> Binding<Bool> {
        Binding(get: { framingTarget == target }, set: { shown in
            if shown { framingTarget = target }
            else if framingTarget == target { framingTarget = nil }
        })
    }

    private func framingSheet(for target: FramingTarget) -> some View {
        CallFramingSheet(title: target == .avatar ? L10n.text("头像取景") : L10n.text("背景取景"),
                         url: target == .avatar ? avatarURL : backgroundURL,
                         kind: target == .avatar ? .image : backgroundKind,
                         framing: target == .avatar ? $draft.profile.avatarFraming : $draft.profile.backgroundFraming,
                         allowsBlur: ownerKind != .localUser,
                         previewKind: target == .background ? .background : (ownerKind == .localUser ? .local : .avatar))
    }

    private func filePresentation(for target: CallProfileAssetTarget) -> Binding<Bool> {
        Binding(get: { fileTarget == target }, set: { shown in
            if shown { fileTarget = target }
            else if fileTarget == target { fileTarget = nil }
        })
    }

    private func fileTypes(for target: CallProfileAssetTarget) -> [UTType] {
        if target == .avatar { return [.image] }
        return [.image, .movie, .video] + [UTType(filenameExtension: "avi")].compactMap { $0 }
    }

    private func handleFileImport(_ result: Result<URL, Error>, target: CallProfileAssetTarget) {
        switch result {
        case .success(let url):
            if target == .background && MediaExtensions.video.contains(url.pathExtension.lowercased()) {
                draft.importVideo(from: url)
            } else { draft.importImage(from: url, target: target) }
        case .failure(let error):
            if (error as? CocoaError)?.code != .userCancelled { draft.error = error.localizedDescription }
        }
    }

    private func chooseFile(_ target: CallProfileAssetTarget) { fileTarget = target }
}

struct CallProfileEditorSheet: View {
    let title: String
    let ownerKind: CallProfileOwnerKind
    var inheritedAvatarURL: URL?
    var inheritedBackgroundURL: URL?
    var inheritedBackgroundKind: CallBackgroundKind = .image
    var inheritedAvatarFraming: CallFraming?
    var inheritedBackgroundFraming: CallFraming?
    let onSave: (CallProfile) throws -> Void
    @StateObject private var draft: CallProfileDraft
    @Environment(\.dismiss) private var dismiss

    init(title: String, ownerKind: CallProfileOwnerKind, profile: CallProfile,
         inheritedAvatarURL: URL? = nil, inheritedBackgroundURL: URL? = nil,
         inheritedBackgroundKind: CallBackgroundKind = .image,
         inheritedAvatarFraming: CallFraming? = nil, inheritedBackgroundFraming: CallFraming? = nil,
         onSave: @escaping (CallProfile) throws -> Void) {
        self.title = title; self.ownerKind = ownerKind
        self.inheritedAvatarURL = inheritedAvatarURL; self.inheritedBackgroundURL = inheritedBackgroundURL
        self.inheritedBackgroundKind = inheritedBackgroundKind
        self.inheritedAvatarFraming = inheritedAvatarFraming; self.inheritedBackgroundFraming = inheritedBackgroundFraming
        self.onSave = onSave
        _draft = StateObject(wrappedValue: CallProfileDraft(profile: profile))
    }

    var body: some View {
        NavigationStack {
            AppForm {
                CallProfileFields(draft: draft, ownerKind: ownerKind,
                                  inheritedAvatarURL: inheritedAvatarURL, inheritedBackgroundURL: inheritedBackgroundURL,
                                  inheritedBackgroundKind: inheritedBackgroundKind,
                                  inheritedAvatarFraming: inheritedAvatarFraming, inheritedBackgroundFraming: inheritedBackgroundFraming)
            }
            .appNavigationColors().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            if ownerKind == .localUser { draft.profile.avatarFraming.fillMode = .black }
                            try onSave(draft.profile)
                            draft.commit(); dismiss()
                        } catch { draft.error = L10n.text("没有保存本次修改：\(error.localizedDescription)") }
                    }.disabled(draft.isLoading).accessibilityIdentifier("saveCallProfile")
                }
            }
            .onDisappear { draft.cancel() }
        }
    }
}
