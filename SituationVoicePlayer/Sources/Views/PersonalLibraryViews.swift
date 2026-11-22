import SwiftUI

struct CreatorAvatarView: View {
    let path: String?
    let name: String
    var size: CGFloat = 56
    var placeholderStyle: AnyShapeStyle = AppTheme.secondaryText

    var body: some View {
        Group {
            if let path {
                CoverImageView(path: path, cornerRadius: size / 2)
            } else {
                Circle().fill(AppTheme.iconTint.opacity(0.12))
                    .overlay { Image(systemName: "person.fill").font(.system(size: size * 0.4)).foregroundStyle(placeholderStyle) }
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .accessibilityHidden(true)
    }
}

struct PersonalWorkRow: View {
    let work: WorkRecord
    @ObservedObject var store: LibraryStore

    private var creator: CreatorRecord? { store.creator(id: work.creatorID) }
    private var duration: String {
        let seconds = work.totalDurationMS / 1_000
        if seconds >= 3_600 { return L10n.text("\(seconds / 3_600) 小时 \((seconds % 3_600) / 60) 分") }
        return seconds > 0 ? "\(seconds / 60):" + String(format: "%02d", seconds % 60) : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CreatorAvatarView(path: creator.flatMap { store.creatorAvatarPath($0) },
                                  name: creator?.name ?? L10n.text("待填写"), size: 34)
                Text(creator?.name ?? L10n.text("创作者待填写"))
                    .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .offset(y: 4)
                Spacer(minLength: 0)
            }

            Text(work.title).font(.headline).foregroundStyle(AppTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)

            HStack(spacing: 10) {
                if !duration.isEmpty { Text(duration) }
                if work.trackCount > 1 || work.videoCount > 0 { Text(work.mediaCountText) }
                if work.hasResumePoint { Label("续播", systemImage: "clock") }
                Spacer(minLength: 0)
                if work.favorite { Image(systemName: "heart.fill").foregroundStyle(AppTheme.painted(.pink, AppTheme.iconTint)) }
            }
            .font(.caption).foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct CreatorProfileView: View {
    let creatorID: Int64
    @ObservedObject var store: LibraryStore
    @State private var editing = false
    @State private var selectedWork: WorkRecord?
    @StateObject private var workDrag = MediaWorkDragSession()

    private var creator: CreatorRecord? { store.creator(id: creatorID) }
    private var works: [WorkRecord] { store.works(forCreatorID: creatorID) }

    var body: some View {
        let displayedWorks = works
        let visibleIDs = displayedWorks.map(\.id)
        return Group {
            if let creator {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if let cover = store.creatorCoverPath(creator) {
                            CoverImageView(path: cover, contentMode: .fit)
                                .frame(maxHeight: 240).frame(maxWidth: .infinity)
                                .accessibilityIdentifier("creatorProfileCover")
                        }
                        HStack(spacing: 14) {
                            CreatorAvatarView(path: store.creatorAvatarPath(creator), name: creator.name, size: 72)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(creator.name).font(.title2.bold()).foregroundStyle(AppTheme.primaryText).fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("creatorProfileName")
                                Text("\(displayedWorks.count) 个作品").font(.caption).foregroundStyle(AppTheme.secondaryText)
                            }
                        }
                        if !creator.note.isEmpty {
                            Text(creator.note).font(.subheadline).foregroundStyle(AppTheme.primaryText).textSelection(.enabled)
                                .accessibilityIdentifier("creatorProfileNote")
                        }
                        if displayedWorks.isEmpty {
                            ContentUnavailableView("还没有关联作品", systemImage: "waveform",
                                description: Text("导入个人音声时选择这位创作者，或在作品资料中修改归属。"))
                        } else {
                            if store.sortOrder == .custom { MediaWorkOrderingHint() }
                            ForEach(displayedWorks) { work in
                                PersonalWorkCardView(work: work, store: store,
                                    accessibilityID: "creatorWork-\(work.id)",
                                    onShowDetails: { selectedWork = work },
                                    onMoveUp: mediaWorkMoveAction(work: work, offset: -1, visibleIDs: visibleIDs, store: store, session: workDrag),
                                    onMoveDown: mediaWorkMoveAction(work: work, offset: 1, visibleIDs: visibleIDs, store: store, session: workDrag))
                                    .modifier(MediaWorkReordering(work: work, visibleIDs: visibleIDs, store: store, session: workDrag))
                            }
                        }
                    }.padding(16)
                }
            } else {
                ContentUnavailableView("找不到创作者", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
        .personalWorkEditorPresentation(store: store)
        .appNavigationColors(contentTitle: true).navigationTitle(creator?.name ?? L10n.text("创作者"))
        .navigationBarTitleDisplayMode(.inline)
        .appPageBackground()
        .onChange(of: visibleIDs) { _, _ in workDrag.invalidate() }
        .onChange(of: store.sortOrder) { _, _ in workDrag.invalidate() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in workDrag.invalidate() }
        .onDisappear { workDrag.invalidate() }
        .navigationDestination(item: $selectedWork) { work in
            PersonalWorkInfoView(work: work, store: store)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("排序", selection: $store.sortOrder) {
                        ForEach(WorkSortOrder.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel("作品排序")
                .accessibilityIdentifier("creatorWorkSort")
                .onChange(of: store.sortOrder) { _, _ in store.applySearchAndSort() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑资料") { editing = true }.disabled(creator == nil)
                    .accessibilityIdentifier("editCreator")
            }
        }
        .porcelainSheet(isPresented: $editing) {
            CreatorEditorSheet(creator: creator, store: store) { _ in }
        }
    }
}
