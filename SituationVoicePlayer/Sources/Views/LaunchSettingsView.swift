import SwiftUI

struct LaunchSettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @ObservedObject private var voice = OpeningVoicePlayer.shared
    @State private var selection = OpeningVoiceSelection.load()
    @State private var showsSources = false

    var body: some View {
        AppList {
            Section("应用图标") {
                HStack(spacing: 16) {
                    Image("ApprovedAppIcon").resizable().frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    Text("厮磨 · 米白")
                }
            }
            Section {
                Button("预览开屏动画") {
                    voice.stop()
                    LaunchExperience.shared.preview()
                }
                    .accessibilityIdentifier("previewLaunchArtwork")
            } footer: { Text("开屏动画仅在冷启动时播放，返回 App 时不会重播。动画预览不播放语音。") }
            Section {
                Button { showsSources = true } label: {
                    LabeledContent("开屏语音", value: selection?.title ?? L10n.text("无声"))
                }.accessibilityIdentifier("selectOpeningVoice")
                if selection != nil {
                    Button(voice.isPlaying ? L10n.text("停止试听") : L10n.text("试听（最多 10 秒）")) {
                        if voice.isPlaying { voice.stop() }
                        else { voice.startSelection(in: store, automatic: false) }
                    }
                    .disabled(player.isPlaying || player.isLoadingMedia || player.isInCall || player.isPresentingVideoPreview)
                    .accessibilityIdentifier("previewOpeningVoice")
                    Button("设为无声") {
                        voice.stop()
                        UserDefaults.standard.removeObject(forKey: OpeningVoiceSelection.defaultsKey)
                        selection = nil
                    }.accessibilityIdentifier("clearOpeningVoice")
                }
                if let message = voice.message, selection != nil {
                    Text(message).font(.footnote).foregroundStyle(AppTheme.secondaryText)
                }
            } header: { Text("开屏语音") } footer: {
                Text("默认无声。可选择媒体库音频或已保存的摘选，从开头播放最多 10 秒；不会计入收听记录。播放作品、进入后台或耳机断开时停止。其他 App 正在播放声音时，冷启动保持无声。")
            }
        }
        .appNavigationColors().navigationTitle(L10n.text("启动与图标"))
        .porcelainSheet(isPresented: $showsSources) {
            OpeningVoiceSourceSheet { choice in selection = choice }
        }
        .onDisappear { voice.stop() }
    }
}

private struct OpeningVoiceSourceSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    var onSelect: (OpeningVoiceSelection) -> Void
    @State private var works: [WorkRecord] = []
    @State private var error: String?
    @State private var search = ""

    private var matchingWorks: [WorkRecord] {
        works.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            AppList {
                Section("已保存的摘选") {
                    ForEach(store.playlistEntries.filter { $0.isClip && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }) { entry in
                        Button { select(.init(kind: .clip, id: entry.id, title: clipTitle(entry))) } label: {
                            VStack(alignment: .leading) {
                                Text(clipTitle(entry))
                                Text(entry.workTitle).font(.caption).foregroundStyle(AppTheme.secondaryText)
                            }
                        }.accessibilityIdentifier("openingVoiceClip-\(entry.id)")
                    }
                }
                Section("媒体库音频") {
                    ForEach(matchingWorks) { work in
                        NavigationLink(work.title) {
                            List(store.groupedTracks(for: work).flatMap(\.tracks).filter { !$0.isVideo }) { track in
                                Button(track.displayTitle) {
                                    select(.init(kind: .track, id: track.id, title: track.displayTitle))
                                }.appListRows().accessibilityIdentifier("openingVoiceTrack-\(track.id)")
                            }.appListSurface().appNavigationColors(contentTitle: true).navigationTitle(work.title)
                        }
                    }
                }
            }
            .appNavigationColors().navigationTitle(L10n.text("选择开屏语音"))
            .searchable(text: $search, prompt: L10n.text("搜索作品或摘选"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task {
                do { works = try store.repository?.works() ?? [] }
                catch { self.error = error.localizedDescription }
            }
            .alert("无法选择开屏语音", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("确定") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func select(_ choice: OpeningVoiceSelection) {
        do {
            _ = try OpeningVoicePlayer.duration(for: choice.resolve(in: store))
            try choice.save()
            OpeningVoicePlayer.shared.stop()
            onSelect(choice)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func clipTitle(_ entry: SavedPlaylistEntry) -> String {
        if let start = entry.startMS, let end = entry.endMS {
            return "\(entry.title) · \(SubtitleTime.clock(start))–\(SubtitleTime.clock(end))"
        }
        if let duration = entry.clipDurationMS {
            return "\(entry.title) · \(SubtitleTime.clock(duration))"
        }
        return entry.title
    }
}
