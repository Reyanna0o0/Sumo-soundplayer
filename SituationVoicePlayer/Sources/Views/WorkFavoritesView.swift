import SwiftUI

struct WorkFavoritesView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var creating = false
    @State private var managing = false
    @State private var editing: NamedCollection?
    @State private var removing: NamedCollection?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("新建收藏夹", systemImage: "folder.badge.plus") { creating = true }
                    .accessibilityIdentifier("newFavoriteCollection")
                Spacer()
                Button(managing ? L10n.text("完成") : L10n.text("管理分类")) { managing.toggle() }
                    .accessibilityIdentifier("manageFavoriteCollections")
                    .accessibilityValue(managing ? L10n.text("正在管理") : L10n.text("浏览"))
            }
            .padding(.horizontal).padding(.vertical, 8)
            List {
                ForEach(store.favoriteGroups) { group in
                    Group {
                        if managing {
                            collectionRow(group)
                        } else {
                            NavigationLink {
                                FavoriteGroupDetail(groupID: group.id)
                                    .toolbar(.visible, for: .navigationBar)
                            } label: {
                                collectionRow(group)
                            }
                        }
                    }
                    .accessibilityIdentifier("favoriteCollection-\(group.id)")
                    .contextMenu {
                        CollectionContextActions(group: group, kind: .favorites,
                            rename: { editing = group }, remove: { removing = group })
                    }
                    .moveDisabled(!managing)
                    .porcelainPlainRow()
                }
                .onMove { source, destination in
                    var ids = store.favoriteGroups.map(\.id)
                    ids.move(fromOffsets: source, toOffset: destination)
                    do { try store.orderCollections(.favorites, ids: ids) }
                    catch { message = error.localizedDescription }
                }
            }
            .listStyle(.plain)
            .porcelainListBackground(AppTheme.card)
            .environment(\.editMode, .constant(managing ? .active : .inactive))
            .accessibilityIdentifier("favoriteCollectionsList")
            .modifier(ScrollContentEdges.library)
        }
        .porcelainSheet(isPresented: $creating) {
            CollectionNameEditor(title: L10n.text("新建收藏夹")) { _ = try store.createCollection(.favorites, name: $0) }
        }
        .modifier(CollectionManagementActions(kind: .favorites, editing: $editing,
            removing: $removing, message: $message))
        .onChange(of: store.currentLibrary) { _, _ in
            managing = false
            editing = nil
            removing = nil
        }
    }

    private func collectionRow(_ group: NamedCollection) -> some View {
        let works = store.favoriteWorks.filter {
            $0.libraryKind == store.currentLibrary && store.favoriteMemberships[$0.id]?.contains(group.id) == true
        }
        return HStack(spacing: 12) {
            CoverImageView(path: works.first?.resolvedCoverPath)
                .frame(width: 80, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                if managing {
                    CollectionRenameLabel(group: group) { editing = group }
                } else {
                    Text(group.name)
                }
                Text("\(works.count) 部作品").font(.caption).foregroundStyle(AppTheme.secondaryText)
            }
            Spacer(minLength: 0)
            if managing && group.id != CollectionKind.favorites.defaultID {
                CollectionDeleteButton(group: group) { removing = group }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct FavoriteGroupDetail: View {
    let groupID: Int64
    @EnvironmentObject private var store: LibraryStore
    @State private var selectedWork: WorkRecord?
    private var works: [WorkRecord] {
        store.favoriteWorks.filter { $0.libraryKind == store.currentLibrary && store.favoriteMemberships[$0.id]?.contains(groupID) == true }
    }
    var body: some View {
        Group {
            if works.isEmpty {
                ContentUnavailableView("收藏夹里还没有作品", systemImage: "heart",
                                       description: Text("在作品详情或播放器中点爱心，选中这个收藏夹。"))
            } else if store.currentLibrary == .personal {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(works) { work in
                            PersonalWorkCardView(work: work, store: store,
                                onShowDetails: { selectedWork = work })
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .background(AppTheme.isPurple ? .clear : AppTheme.background)
            } else {
                List(works) { work in
                    NavigationLink {
                        WorkDetailView(work: work, store: store)
                            .toolbar(.visible, for: .navigationBar)
                    } label: {
                        HStack(spacing: 12) {
                            CoverImageView(path: work.resolvedCoverPath)
                                .frame(width: 80, height: 60)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(work.title).lineLimit(2)
                                if !work.subtitle.isEmpty {
                                    Text(work.subtitle).font(.caption).foregroundStyle(AppTheme.secondaryText)
                                }
                            }
                        }
                    }
                    .porcelainPlainRow()
                }
                .listStyle(.plain)
                .porcelainListBackground(AppTheme.background)
            }
        }
        .personalWorkEditorPresentation(store: store)
        .frame(maxWidth: AppTheme.usesCustomPalette ? .infinity : nil, maxHeight: AppTheme.usesCustomPalette ? .infinity : nil)
        .appPageBackground(AppTheme.painted(.clear, AppTheme.background))
        .appNavigationColors(contentTitle: true).navigationTitle(store.favoriteGroups.first { $0.id == groupID }?.name ?? L10n.text("收藏夹"))
        .navigationDestination(item: $selectedWork) { work in
            PersonalWorkInfoView(work: work, store: store)
                .toolbar(.visible, for: .navigationBar)
        }
    }
}

struct WorkFavoritePicker: View {
    let workID: Int64
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<Int64> = []
    @State private var creating = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section("选择收藏夹") {
                    ForEach(store.favoriteGroups) { group in
                        Button {
                            if !selection.insert(group.id).inserted { selection.remove(group.id) }
                        } label: {
                            HStack {
                                Text(group.name).foregroundStyle(AppTheme.primaryText)
                                Spacer()
                                if selection.contains(group.id) { Image(systemName: "checkmark") }
                            }.contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(selection.contains(group.id) ? .isSelected : [])
                        .accessibilityIdentifier("pickFavorite-\(group.id)")
                        .porcelainPlainRow(AppTheme.card)
                    }
                    Button("新建收藏夹", systemImage: "folder.badge.plus") { creating = true }
                        .porcelainPlainRow(AppTheme.card)
                }
                if store.isWorkFavorite(id: workID) {
                    Button("取消收藏这部作品", role: .destructive) { commit([]) }
                        .porcelainPlainRow(AppTheme.card)
                }
                if let message {
                    Text(message).foregroundStyle(.red)
                        .porcelainPlainRow(AppTheme.card)
                }
            }
            .porcelainListBackground(AppTheme.background)
            .appNavigationColors().navigationTitle(L10n.text("收藏夹"))
            .safeAreaInset(edge: .top) { Text("收藏整部作品").font(.headline).fixedSize(horizontal: false, vertical: true).padding().frame(maxWidth: .infinity).background(AppTheme.background) }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commit(selection) }.disabled(selection.isEmpty)
                        .accessibilityIdentifier("saveFavoriteSelection")
                }
            }
            .task(id: workID) {
                selection = store.favoriteMemberships[workID] ?? [CollectionKind.favorites.defaultID]
            }
            .porcelainSheet(isPresented: $creating) {
                CollectionNameEditor(title: L10n.text("新建收藏夹")) { name in
                    selection.insert(try store.createCollection(.favorites, name: name))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func commit(_ ids: Set<Int64>) {
        do { try store.setFavoriteGroups(workID: workID, groupIDs: ids); dismiss() }
        catch { message = error.localizedDescription }
    }
}
