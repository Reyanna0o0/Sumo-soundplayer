import SwiftUI

/// The add action always opens the playlist destination page, including with only one list.
struct PlaylistDestinationSheet: View {
    let item: PlaybackQueueItem
    var onAdded: (String) -> Void = { _ in }
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            AppList {
                Section {
                    Text(item.trackTitle).font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                } header: { Text("选择播放列表").foregroundStyle(AppTheme.secondaryText) }
                ForEach(store.playlistGroups.filter { !$0.isClips }) { group in
                    let entries = store.playlistEntries.filter { $0.groupID == group.id }
                    let contains = entries.contains { item.mediaID != nil && $0.wholeMediaID == item.mediaID }
                    Button {
                        do {
                            // Recheck the latest in-memory state as well as disabling the row.
                            // A duplicate selection or failed write must not announce a new save.
                            guard !store.playlistEntries.contains(where: {
                                $0.groupID == group.id && item.mediaID != nil && $0.wholeMediaID == item.mediaID
                            }) else { return }
                            try store.addWholeTrack(item, groupID: group.id)
                            onAdded(group.name)
                            dismiss()
                        }
                        catch { message = error.localizedDescription }
                    } label: {
                        HStack(spacing: 12) {
                            CollectionArtwork(entry: entries.first, clips: false, usesPlainBackground: true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.name).font(.headline)
                                Text("\(entries.count) 首曲目").font(.caption).foregroundStyle(AppTheme.secondaryText)
                            }
                            Spacer()
                            if contains { Label("已加入", systemImage: "checkmark").font(.caption) }
                            else { Image(systemName: "plus") }
                        }.frame(minHeight: 54).contentShape(Rectangle())
                    }
                    .disabled(contains)
                    .accessibilityIdentifier("addToPlaylist-\(group.id)")
                }
                Button("新建播放列表", systemImage: "plus") { naming = true }
                    .accessibilityIdentifier("newDestinationPlaylist")
            }
            .accessibilityIdentifier("playlistDestinationList")
            .appNavigationColors().navigationTitle(L10n.text("加入播放列表")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .porcelainSheet(isPresented: $naming) {
                CollectionNameEditor(title: L10n.text("新建播放列表")) {
                    _ = try store.createCollection(.playlists, name: $0)
                }
            }
            .alert("无法加入播放列表", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") { message = nil }
            } message: { Text(message ?? "") }
        }
    }
}

struct SavedPlaylistView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var showClips = false
    @State private var managing = false
    @State private var namingGroup = false
    @State private var editing: NamedCollection?
    @State private var removing: NamedCollection?
    @State private var message: String?

    private var collectionKind: CollectionKind { showClips ? .clips : .playlists }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    tab(L10n.text("播放列表"), clips: false)
                    tab(L10n.text("摘选"), clips: true)
                }
                .padding(.horizontal, 14)
                Divider().hidden()
                HStack {
                    Spacer()
                    Button { managing.toggle() } label: {
                        Text(managing ? L10n.text("完成") : L10n.text("管理分类"))
                            .foregroundStyle(AppTheme.textStyle(.foreground, AppTheme.emphasisInk))
                    }
                    .tint(AppTheme.usesCustomPalette ? AppTheme.emphasisInk : nil)
                    .accessibilityIdentifier("managePlaylistGroups")
                    .accessibilityValue(managing ? L10n.text("正在管理") : L10n.text("浏览"))
                }
                .padding(.horizontal, 18)
                .padding(.top, 10).padding(.bottom, 2)
                collections
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    namingGroup = true
                } label: {
                    Image(systemName: "plus").font(.title.weight(.light))
                        .frame(width: 54, height: 54).background(AppTheme.painted(.white, AppTheme.isPurple ? .white : AppTheme.card), in: Circle())
                        .foregroundStyle(AppTheme.painted(Color(red: 0.21, green: 0.19, blue: 0.39), AppTheme.isPurple ? AppTheme.rgb(0x363063) : AppTheme.iconTint))
                        .shadow(color: AppTheme.shadow.opacity(0.22), radius: 7, y: 3)
                }
                .accessibilityLabel(showClips ? L10n.text("新建摘选集") : L10n.text("新建播放列表"))
                .accessibilityIdentifier("newPlaylistGroup")
                .padding(20)
            }
            .foregroundStyle(AppTheme.painted(.white, AppTheme.ink))
            .containerBackground(.clear, for: .navigation)
            .toolbar(.hidden, for: .navigationBar)
            .porcelainSheet(isPresented: $namingGroup) {
                CollectionNameEditor(title: showClips ? L10n.text("新建摘选集") : L10n.text("新建播放列表")) {
                    _ = try store.createCollection(collectionKind, name: $0)
                }
            }
            .modifier(CollectionManagementActions(kind: collectionKind, editing: $editing,
                removing: $removing, message: $message))
            .onChange(of: showClips) { _, _ in
                managing = false
                editing = nil
                removing = nil
            }
        }
    }

    private func tab(_ title: String, clips: Bool) -> some View {
        Button { showClips = clips } label: {
            VStack(spacing: 0) {
                Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(AppTheme.painted(.white.opacity(showClips == clips ? 1 : 0.65),
                                                  showClips == clips ? AppTheme.emphasisInk : AppTheme.secondary))
                Rectangle().fill(AppTheme.painted(.white, AppTheme.accent).opacity(showClips == clips ? 1 : 0)).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(showClips == clips ? .isSelected : [])
        .accessibilityIdentifier(clips ? "clipCollectionsTab" : "trackCollectionsTab")
    }

    @ViewBuilder private var collections: some View {
        let groups = store.playlistGroups.filter { $0.isClips == showClips }
        let byGroup = Dictionary(grouping: store.playlistEntries, by: \.groupID)
        if groups.isEmpty {
            ContentUnavailableView(showClips ? L10n.text("还没有摘选集") : L10n.text("还没有播放列表"),
                systemImage: showClips ? "scissors" : "music.note.list",
                description: Text("点右下角的加号创建。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if managing {
            List {
                ForEach(groups) { group in
                    collectionRow(group, entries: byGroup[group.id] ?? [], isManaging: true)
                        .accessibilityIdentifier("collection-\(group.id)")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
                }
                .onMove { source, destination in
                    var ids = groups.map(\.id)
                    ids.move(fromOffsets: source, toOffset: destination)
                    do { try store.orderCollections(collectionKind, ids: ids) }
                    catch { message = error.localizedDescription }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
            .contentMargins(.bottom, 82, for: .scrollContent)
            .environment(\.editMode, .constant(.active))
            .environment(\.colorScheme, AppTheme.isPorcelain ? .light : .dark)
            .modifier(ScrollContentEdges())
            .accessibilityIdentifier("inlineCollectionManagementList")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        let items = byGroup[group.id] ?? []
                        NavigationLink {
                            SavedCollectionDetail(group: group)
                        } label: {
                            collectionRow(group, entries: items, isManaging: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("collection-\(group.id)")
                        .contextMenu {
                            let named = NamedCollection(id: group.id, name: group.name)
                            CollectionContextActions(group: named, kind: collectionKind,
                                rename: { editing = named }, remove: { removing = named })
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 82)
            }
            .modifier(ScrollContentEdges())
        }
    }

    private func collectionRow(_ group: SavedPlaylistGroup, entries: [SavedPlaylistEntry], isManaging: Bool) -> some View {
        let named = NamedCollection(id: group.id, name: group.name)
        return HStack(spacing: 12) {
            CollectionArtwork(entry: entries.first, clips: group.isClips)
            VStack(alignment: .leading, spacing: 4) {
                if isManaging {
                    CollectionRenameLabel(group: named) { editing = named }.font(.headline)
                } else {
                    Text(group.name).font(.headline).lineLimit(2)
                }
                Text(group.isClips ? L10n.text("\(entries.count) 个摘选") : L10n.text("\(entries.count) 首曲目"))
                    .font(.caption).foregroundStyle(AppTheme.painted(.white.opacity(0.68), AppTheme.secondary))
            }
            Spacer(minLength: 0)
            if isManaging && group.id != collectionKind.defaultID {
                CollectionDeleteButton(group: named) { removing = named }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

struct PlaylistBackdrop: View {
    var body: some View {
        let colors = AppTheme.usesCustomPalette
            ? [AppTheme.background, AppTheme.card, AppTheme.surface]
            : [Color(red: 0.49, green: 0.31, blue: 0.53),
                                Color(red: 0.115, green: 0.135, blue: 0.29),
                                Color(red: 0.032, green: 0.045, blue: 0.095)]
        if AppTheme.isPurple {
            Color.clear.appPageBackground()
        } else {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
    }
}

private struct CollectionArtwork: View {
    @EnvironmentObject private var store: LibraryStore
    let entry: SavedPlaylistEntry?
    let clips: Bool
    var usesPlainBackground = false
    private let artworkSize = CGSize(width: 80, height: 60)
    @State private var cover: String?

    var body: some View {
        Group {
            if let cover {
                CoverImageView(path: cover, cornerRadius: 6)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(AppTheme.painted(usesPlainBackground ? Color.secondary.opacity(0.12) : Color.white.opacity(0.14),
                                           AppTheme.isPurple && !usesPlainBackground ? .white.opacity(0.14) : AppTheme.surface))
                    .overlay {
                        Image(systemName: clips ? "scissors" : "music.note.list")
                            .foregroundStyle(AppTheme.painted(usesPlainBackground ? .secondary : .white.opacity(0.85), AppTheme.secondary))
                    }
            }
        }
        .frame(width: artworkSize.width, height: artworkSize.height)
        .task(id: entry?.id) { cover = entry.flatMap { store.entryCoverPath($0) } }
        .accessibilityHidden(true)
    }
}

private struct SavedCollectionDetail: View {
    let group: SavedPlaylistGroup
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @State private var message: String?
    @State private var pendingRemoval: SavedPlaylistEntry?
    @State private var merging = false
    @State private var exportEntry: SavedPlaylistEntry?
    @State private var movingEntry: SavedPlaylistEntry?
    @State private var ordering = false

    private var entries: [SavedPlaylistEntry] { store.playlistEntries.filter { $0.groupID == group.id } }

    var body: some View {
        let displayed = entries
        return Group {
            if entries.isEmpty {
                ContentUnavailableView(group.isClips ? L10n.text("这个摘选集还是空的") : L10n.text("这个播放列表还是空的"),
                    systemImage: group.isClips ? "scissors" : "music.note.list",
                    description: Text(group.isClips ? L10n.text("在播放页标记起点，再保存片段到这里。") : L10n.text("在播放页将喜欢的整首音频加入这里。")))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(displayed) { entry in
                        HStack(spacing: 12) {
                            Button { play(entry) } label: {
                                HStack(spacing: 12) {
                                    CollectionArtwork(entry: entry, clips: group.isClips)
                                    EntryLabel(entry: entry)
                                    Spacer()
                                    Image(systemName: "play.circle")
                                        .font(.system(size: 22))
                                        .foregroundStyle(AppTheme.painted(.white.opacity(0.65), AppTheme.isPurple ? AppTheme.iconTint : AppTheme.secondary))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("playEntry-\(entry.id)")
                            Menu {
                                Button("更改分类", systemImage: "folder") { movingEntry = entry }
                                    .accessibilityIdentifier("moveEntry-\(entry.id)")
                                if entry.isClip {
                                    Button("导出音频…", systemImage: "square.and.arrow.up") { exportEntry = entry }
                                        .accessibilityIdentifier("exportClip-\(entry.id)")
                                }
                                Button("移除", systemImage: "trash", role: .destructive) { pendingRemoval = entry }
                            } label: {
                                Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                            }
                            .accessibilityLabel("\(entry.title)的操作")
                            .accessibilityIdentifier(entry.isClip ? "clipOptions-\(entry.id)" : "trackOptions-\(entry.id)")
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: group.isClips ? 12 : 4, leading: 20,
                                                 bottom: group.isClips ? 12 : 4, trailing: 20))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 92 }
                        .listRowSeparatorTint(AppTheme.painted(.white.opacity(0.15), AppTheme.separator))
                        .swipeActions {
                            Button("移除", role: .destructive) { pendingRemoval = entry }
                        }

                    }
                    .onMove { source, destination in
                        let original = displayed.map(\.id)
                        var ids = original
                        ids.move(fromOffsets: source, toOffset: destination)
                        do { try store.orderPlaylistEntries(groupID: group.id, ids: ids, expectedIDs: original) }
                        catch { message = error.localizedDescription }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .modifier(ScrollContentEdges())
                .environment(\.editMode, .constant(ordering ? .active : .inactive))
                .accessibilityIdentifier("savedCollectionEntries")
            }
        }
        .foregroundStyle(AppTheme.painted(.white, AppTheme.ink))
        .containerBackground(.clear, for: .navigation)
        .appNavigationColors(contentTitle: true).navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarColorScheme(AppTheme.isPorcelain ? .light : .dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(ordering ? L10n.text("完成") : L10n.text("调整顺序")) { ordering.toggle() }
                    .disabled(entries.count < 2 && !ordering)
                    .accessibilityIdentifier("playlistEntryOrderToggle")
            }
            if group.isClips {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("拼接摘选") { merging = true }
                        .accessibilityIdentifier("composeClips")
                        .disabled(store.playlistEntries.filter(\.isClip).count < 2)
                }
            }
        }
        .porcelainSheet(isPresented: $merging) { ClipCompositionView(group: group) }
        .porcelainSheet(item: $exportEntry) { entry in
            SavedClipExportSheet(entry: entry)
        }
        .porcelainSheet(item: $movingEntry) { entry in
            PlaylistEntryGroupPicker(entry: entry)
        }
        .onDisappear { ordering = false }
        .alert("播放列表", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
        .alert("移除「\(pendingRemoval?.title ?? "")」？", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { entry in
            Button(entry.isClip ? L10n.text("删除保存的音频") : (entry.attachmentID == nil ? L10n.text("从列表移除整首") : L10n.text("从列表移除视频")), role: .destructive) {
                do { try store.removePlaylistEntry(entry) }
                catch { message = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func play(_ entry: SavedPlaylistEntry) {
        var items: [PlaybackQueueItem] = []
        var selected: Int?
        for saved in entries {
            guard let item = store.playlistItem(for: saved) else { continue }
            if saved.id == entry.id { selected = items.count }
            items.append(item)
        }
        guard let selected else {
            message = entry.isClip ? L10n.text("找不到这份保存的音频。") : L10n.text("无法读取原媒体，请检查作品文件夹是否仍可访问。")
            return
        }
        player.play(items: items, startingAt: selected, collection: group)
        if player.currentItem != nil { player.isPlayerSheetPresented = true }
        else { message = player.errorMessage ?? L10n.text("无法开始播放") }
    }
}

private struct PlaylistEntryGroupPicker: View {
    let entry: SavedPlaylistEntry
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?

    var body: some View {
        NavigationStack {
            AppList {
                Section {
                    Text(entry.title).font(.headline)
                }
                Section {
                    ForEach(store.playlistGroups.filter { $0.isClips == entry.isClip }) { destination in
                        Button {
                            do {
                                try store.movePlaylistEntry(entry, to: destination.id)
                                dismiss()
                            } catch { message = error.localizedDescription }
                        } label: {
                            HStack {
                                Text(destination.name)
                                Spacer()
                                if destination.id == entry.groupID { Image(systemName: "checkmark") }
                            }
                        }
                        .disabled(destination.id == entry.groupID)
                        .accessibilityIdentifier("moveEntryTarget-\(destination.id)")
                    }
                } header: {
                    Text("移动到")
                } footer: {
                    Text("选择目标分类，原有内容和记录会保留。")
                }
            }
            .appNavigationColors().navigationTitle(L10n.text("更改分类"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .alert("更改分类", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") { message = nil }
            } message: { Text(message ?? "") }
        }
    }
}

private struct EntryLabel: View {
    let entry: SavedPlaylistEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title).font(.headline).lineLimit(2)
            if !entry.workTitle.isEmpty {
                Text(entry.workTitle).font(.caption).foregroundStyle(AppTheme.secondaryText).lineLimit(1)
            }
            if entry.isMerged {
                Label("已拼接\(durationText)", systemImage: "waveform.path").font(.caption.monospacedDigit())
            } else if let start = entry.startMS, let end = entry.endMS {
                Text("原曲 \(SubtitleTime.clock(start)) – \(SubtitleTime.clock(end))\(durationText)")
                    .font(.caption.monospacedDigit()).foregroundStyle(AppTheme.secondaryText)
            }
        }
    }

    private var durationText: String {
        guard let duration = entry.clipDurationMS else { return "" }
        if duration < 1_000 { return L10n.text(" · 时长不足 1 秒") }
        return L10n.text(" · 时长 \(SubtitleTime.clock(duration))")
    }
}

/// 顺序由点选次序决定。即使来源分散在多个集合，生成的音频也统一保存在打开的集合。
private struct ClipCompositionView: View {
    let group: SavedPlaylistGroup
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var orderedIDs: [Int64] = []
    @State private var title = ""
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            AppForm {
                Section {
                    TextField("新音频名称", text: $title)
                        .accessibilityIdentifier("composeTitle")
                } footer: {
                    Text("依次点选要拼接的片段，圆圈中的数字是播放顺序。成品将保存在「\(group.name)」。")
                }
                let clips = Dictionary(grouping: store.playlistEntries.filter(\.isClip), by: \.groupID)
                ForEach(store.playlistGroups.filter(\.isClips)) { source in
                    if let entries = clips[source.id] {
                        Section(source.name) {
                            ForEach(entries) { entry in pickButton(entry) }
                        }
                    }
                }
                if let message { Text(message).foregroundStyle(.red) }
            }
            .disabled(saving)
            .appNavigationColors().navigationTitle(L10n.text("拼接摘选"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: {
                        if saving { ProgressView() }
                        else { Text("合并（\(orderedIDs.count)）") }
                    }
                    .accessibilityIdentifier("composeSave")
                    .disabled(saving || orderedIDs.count < 2 || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func pickButton(_ entry: SavedPlaylistEntry) -> some View {
        let index = orderedIDs.firstIndex(of: entry.id)
        return Button {
            if let index { orderedIDs.remove(at: index) }
            else { orderedIDs.append(entry.id) }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().strokeBorder(index == nil ? AppTheme.secondary : AppTheme.accent, lineWidth: 1.5)
                    if let index {
                        Circle().fill(AppTheme.accent)
                        Text("\(index + 1)").font(.caption.bold()).foregroundStyle(AppTheme.painted(.white, AppTheme.card))
                    }
                }
                .frame(width: 26, height: 26)
                EntryLabel(entry: entry)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composePick-\(entry.id)")
        .accessibilityValue(index.map { L10n.text("第\($0 + 1)段") } ?? L10n.text("未选择"))
    }

    private func save() {
        guard !saving else { return }
        let entriesByID = Dictionary(uniqueKeysWithValues: store.playlistEntries.map { ($0.id, $0) })
        let ordered = orderedIDs.compactMap { entriesByID[$0] }
        guard ordered.count == orderedIDs.count, ordered.count >= 2 else {
            message = L10n.text("选中的片段已改变，请重新选择。")
            orderedIDs = ordered.map(\.id)
            return
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await store.mergeClips(ordered, title: title.trimmingCharacters(in: .whitespacesAndNewlines), groupID: group.id)
                dismiss()
            } catch { message = error.localizedDescription }
        }
    }
}
