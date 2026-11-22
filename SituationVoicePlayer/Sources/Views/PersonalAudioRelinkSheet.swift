import SwiftUI
import UniformTypeIdentifiers

/// Replace an audio source only after the user has reviewed the prepared copy.
/// The existing track identity (and its subtitle edits) stays with the work.
struct PersonalAudioRelinkSheet: View {
    let work: WorkRecord
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTrackID: Int64?
    @State private var pending: PendingAudioRelink?
    @State private var operation: Task<Void, Never>?
    @State private var revision = UUID()
    @State private var active = true
    @State private var preparing = false
    @State private var saving = false
    @State private var showPicker = false
    @State private var showFolderRelink = false
    @State private var message: String?

    private var audioTracks: [TrackRecord] {
        guard work.libraryKind == .personal else { return [] }
        return store.tracks(for: work).filter { !$0.isVideo }
    }
    private var busy: Bool { preparing || saving }

    var body: some View {
        NavigationStack {
            AppList {
                Section {
                    if audioTracks.isEmpty {
                        Text("这部作品没有可重新关联的音频。")
                            .foregroundStyle(AppTheme.secondaryText)
                            .accessibilityIdentifier("personalAudioRelinkEmpty")
                    } else {
                        ForEach(audioTracks) { track in
                            Button {
                                selectedTrackID = track.id
                                showPicker = true
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(track.displayTitle).foregroundStyle(AppTheme.primaryText)
                                        Text("\(track.fileName) · \(duration(track.durationMS))")
                                            .font(.caption).foregroundStyle(AppTheme.secondaryText)
                                    }
                                    Spacer()
                                    Image(systemName: "doc.badge.plus")
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .disabled(busy || pending != nil)
                            .accessibilityIdentifier("personalAudioRelinkTrack-\(track.id)")
                            .accessibilityHint("选择新的音频文件，确认后关联到这条音轨")
                        }
                    }
                } header: {
                    Text("选择要重新关联的音频")
                } footer: {
                    Text("作品资料、分类、字幕编辑和时间保持不变。新音频会复制进 App 并占用空间，原文件和旧副本会保留。")
                }

                if preparing {
                    Section {
                        ProgressView("正在准备音频副本…")
                            .accessibilityIdentifier("personalAudioRelinkPreparing")
                    }
                }
                if let pending {
                    Section {
                        fileSummary(L10n.text("原文件"), name: pending.previousFileName,
                                    durationMS: pending.previousDurationMS,
                                    identifier: "personalAudioRelinkPrevious")
                        fileSummary(L10n.text("新文件"), name: pending.selectedFileName,
                                    durationMS: pending.durationMS,
                                    identifier: "personalAudioRelinkReplacement")
                        LabeledContent("新增空间", value: ByteCountFormatter.string(
                            fromByteCount: pending.byteCount, countStyle: .file))
                        Button("取消这次选择", role: .cancel) { cancelPendingSelection() }
                            .disabled(saving)
                            .accessibilityIdentifier("personalAudioRelinkDiscard")
                    } header: {
                        Text("确认新文件")
                    } footer: {
                        Text("确认后使用新音频播放。字幕时间不会自动调整，请确认新旧音频内容对应。")
                    }
                    .accessibilityIdentifier("personalAudioRelinkPreview")
                }

                Section {
                    Button("修复外部文件夹位置…", systemImage: "folder") {
                        showFolderRelink = true
                    }
                    .disabled(busy || pending != nil)
                    .accessibilityIdentifier("personalAudioRelinkFolder")
                } footer: {
                    Text("原来直接关联的文件夹移动或改名时，可在这里重新配对音频与附件。")
                }
            }
            .appNavigationColors().navigationTitle(L10n.text("重新关联音频"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        cancelPendingSelection()
                        dismiss()
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("personalAudioRelinkClose")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认关联", action: save)
                        .disabled(pending == nil || busy)
                        .accessibilityIdentifier("personalAudioRelinkConfirm")
                }
            }
            .interactiveDismissDisabled(busy)
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.audio]) { result in
                guard active else { return }
                switch result {
                case .success(let url):
                    guard let selectedTrackID else { return }
                    prepare(trackID: selectedTrackID, url: url)
                case .failure(let error):
                    if (error as? CocoaError)?.code != .userCancelled {
                        message = error.localizedDescription
                    }
                }
            }
            .sheet(isPresented: $showFolderRelink) {
                WorkRelinkSheet(work: work, store: store, onSaved: {})
            }
            .alert("重新关联音频", isPresented: Binding(
                get: { message != nil }, set: { if !$0 { message = nil } }
            )) {
                Button("好") { message = nil }
            } message: {
                Text(message ?? "")
            }
            .onAppear { active = true }
            .onDisappear {
                active = false
                cancelPendingSelection()
            }
        }
    }

    private func fileSummary(_ title: String, name: String, durationMS: Int?, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(AppTheme.secondaryText)
            Text(name)
            Text(duration(durationMS)).font(.subheadline).foregroundStyle(AppTheme.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func duration(_ milliseconds: Int?) -> String {
        guard let milliseconds, milliseconds >= 0 else { return L10n.text("时长未知") }
        let seconds = milliseconds / 1_000
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func prepare(trackID: Int64, url: URL) {
        guard !busy, pending == nil else { return }
        let request = UUID()
        revision = request
        preparing = true
        message = nil
        operation = Task { @MainActor in
            do {
                let prepared = try await store.prepareAudioRelink(for: work, trackID: trackID, selectedURL: url)
                guard active, revision == request, !Task.isCancelled else {
                    store.cancelAudioRelink(prepared)
                    return
                }
                pending = prepared
            } catch is CancellationError {
                // The service disposes any unfinished copy; cancellation is not an error dialog.
            } catch {
                if active, revision == request, !Task.isCancelled { message = error.localizedDescription }
            }
            guard revision == request else { return }
            preparing = false
            operation = nil
        }
    }

    private func cancelPendingSelection() {
        revision = UUID()
        operation?.cancel()
        operation = nil
        preparing = false
        if let pending { store.cancelAudioRelink(pending) }
        pending = nil
    }

    private func save() {
        guard !busy, let pending else { return }
        saving = true
        defer { saving = false }
        do {
            try store.commitAudioRelink(pending)
            self.pending = nil
            dismiss()
        } catch {
            store.cancelAudioRelink(pending)
            self.pending = nil
            message = error.localizedDescription
        }
    }
}
