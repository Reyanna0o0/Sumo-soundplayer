import SwiftUI

struct PlaybackQueueSheet: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    private var sourceName: String {
        if let collection = player.queueCollection {
            let name = store.playlistGroups.first { $0.id == collection.id }?.name ?? collection.name
            return (collection.isClips ? L10n.text("摘选 · ") : L10n.text("播放列表 · ")) + name
        }
        return L10n.text("作品 · ") + player.currentWorkTitle
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                AppList {
                    Section {
                        ForEach(player.queue.order, id: \.self) { index in
                            let item = player.queue.items[index]
                            let isCurrent = item.id == player.currentItem?.id
                            Button {
                                if isCurrent { player.resume() }
                                else { player.jump(toItemIndex: index) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.trackTitle).foregroundStyle(AppTheme.primaryText)
                                        QueueTrackDetail(item: item, showWork: player.queueCollection != nil)
                                    }
                                    Spacer()
                                    if item.id == player.sleepTimer.queueTargetID {
                                        Image(systemName: "moon.fill").accessibilityLabel("播完后停止")
                                    }
                                    if isCurrent { Image(systemName: "speaker.wave.2.fill") }
                                }
                                .frame(minHeight: 42)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isCurrent ? .isSelected : [])
                            .accessibilityIdentifier("queueTrack-\(item.trackID)")
                            .id(item.id)
                        }
                        .onMove(perform: player.moveQueueItems)
                    } header: {
                        Text(sourceName)
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("拖动右侧把手调整播放顺序，正在播放的音轨不会从头开始。")
                            if let notice = player.sleepTimerNotice { Text(notice) }
                        }
                    }
                }
                .environment(\.editMode, .constant(.active))
                .accessibilityIdentifier("playbackQueueList")
                .onAppear {
                    if let id = player.currentItem?.id { scroll.scrollTo(id, anchor: .center) }
                }
            }
            .appNavigationColors().navigationTitle(L10n.text("当前播放队列"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("closePlaybackQueue")
                }
            }
        }
        .presentationDetents([.fraction(0.5), .large])
        .presentationDragIndicator(.visible)
        .presentationCompactAdaptation(.sheet)
    }
}

private struct QueueTrackDetail: View {
    let item: PlaybackQueueItem
    let showWork: Bool
    @EnvironmentObject private var store: LibraryStore
    @State private var workTitle = ""

    var body: some View {
        Text(showWork && !workTitle.isEmpty ? "\(workTitle) · \(item.fileType.uppercased())" : item.fileType.uppercased())
            .font(.caption).foregroundStyle(AppTheme.secondaryText).lineLimit(1)
            .onChange(of: store.contentRevision, initial: true) { _, _ in
                if showWork { workTitle = store.displayWorkTitle(for: item) }
            }
    }
}
