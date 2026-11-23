import SwiftUI

/// 媒体库首页：封面墙 + 导入
struct LibraryView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var store: LibraryStore
    @State private var showImport = false
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool
    @State private var showCreatorEditor = false
    @State private var orderingCreators = false
    @State private var creatorOrderError: String?
    private enum HeaderMenu {
        case library, sort
    }
    @Environment(\.colorScheme) private var colorScheme
    @State private var headerMenu: HeaderMenu?
    @State private var sortButtonFrame = CGRect.zero
    private var usesPorcelainMenu: Bool {
        AppTheme.usesChoicePanels(in: colorScheme)
    }
    private var headerIconColor: AnyShapeStyle {
        AppTheme.textStyle(.primary, usesPorcelainMenu ? AppTheme.iconTint : AppTheme.titleInk)
    }
    private static let visibleFilters: [WorkFilter] = [.all, .favorite, .unlistened]
    @State private var libraryTitleFrame = CGRect.zero
    @State private var section: LibraryHomeSection = .works
    @State private var selectedTag: LibraryTag?
    @State private var pendingRemoval: WorkRecord?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedWork: WorkRecord?
    @StateObject private var workDrag = MediaWorkDragSession()
    @StateObject private var collectionArrangement = CollectionWorkArrangement()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var collectionGridFrames: [Int: CGRect] = [:]
    @AppStorage(CollectionWorkDisplay.preferenceKey) private var collectionDisplayRaw = CollectionWorkDisplay.covers.rawValue
    private var collectionDisplay: CollectionWorkDisplay { .resolved(collectionDisplayRaw) }
    private enum LibraryHomeSection: Hashable {
        case works, circles, performers, creators, favorites
        func title(personal: Bool) -> String {
            switch self {
            case .works: return personal ? L10n.text("所有作品") : L10n.text("作品")
            case .circles: return L10n.text("社团")
            case .performers: return L10n.text("声优")
            case .creators: return L10n.text("创作者")
            case .favorites: return L10n.text("收藏")
            }
        }
    }
    private var isPersonal: Bool { store.currentLibrary == .personal }
    private var sections: [LibraryHomeSection] {
        isPersonal ? [.works, .creators, .favorites] : [.works, .circles, .performers, .favorites]
    }
    private var otherLibrary: MediaLibraryKind { isPersonal ? .collection : .personal }
    private var searchPrompt: String {
        isPersonal ? L10n.text("搜索作品 / 创作者") : L10n.text("搜索标题 / 声优 / 社团 / 作品编号")
    }

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize { return [GridItem(.flexible())] }
        if horizontalSizeClass == .compact {
            return Array(repeating: GridItem(.flexible(minimum: 0), spacing: 16, alignment: .top), count: 2)
        }
        return [GridItem(.adaptive(minimum: 168, maximum: 260), spacing: 16, alignment: .top)]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                libraryHomeHeader
                if isSearching { searchField }
                if isPersonal && store.searchText.isEmpty && !store.recentCreators.isEmpty {
                    recentCreators
                }
                Picker("媒体库分类", selection: $section) {
                    ForEach(sections, id: \.self) { item in
                        Text(item.title(personal: isPersonal)).tag(item)
                    }
                }
                .pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 8)
                .accessibilityIdentifier("librarySections")
                if !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   store.otherLibraryMatchCount > 0 {
                    Button {
                        switchLibrary(otherLibrary)
                    } label: {
                        HStack {
                            Text("\(otherLibrary.displayName)还有 \(store.otherLibraryMatchCount) 个匹配作品")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(.footnote).padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    .accessibilityIdentifier("otherLibraryMatches")
                }
                if section == .favorites {
                    WorkFavoritesView()
                } else {
                    browsingContent.modifier(ScrollContentEdges.library)
                }
            }
            .appPageBackground(AppTheme.painted(.clear, AppTheme.libraryHeaderSurface))
            .appNavigationColors().navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: store.searchText) { _, text in
                workDrag.invalidate()
                collectionArrangement.finish()
                if !text.isEmpty { section = .works }
                store.applySearchAndSort()
            }
            .onChange(of: store.currentLibrary) { _, _ in
                workDrag.invalidate()
                collectionArrangement.finish()
                section = .works
                selectedTag = nil
                selectedWork = nil
            }
            .onChange(of: store.sortOrder) { _, _ in workDrag.invalidate(); collectionArrangement.finish() }
            .onChange(of: store.filter) { _, _ in collectionArrangement.finish() }
            .onChange(of: store.contentRevision) { _, _ in collectionArrangement.cancelDrag() }
            .onChange(of: section) { _, _ in workDrag.invalidate(); collectionArrangement.finish() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                headerMenu = nil
                workDrag.invalidate(); collectionArrangement.finish()
            }
            .onDisappear {
                headerMenu = nil
                workDrag.invalidate(); collectionArrangement.finish()
            }
            .safeAreaInset(edge: .bottom) {
                progressBar
            }
            .porcelainSheet(isPresented: $showImport) {
                LibraryImportSheet(store: store, initialLibrary: store.currentLibrary)
            }
            .porcelainSheet(isPresented: $showCreatorEditor) {
                CreatorEditorSheet(creator: nil, store: store) { _ in }
            }
            .confirmationDialog("从媒体库移除作品？", isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
            ), titleVisibility: .visible, presenting: pendingRemoval) { work in
                Button("移除作品", role: .destructive) {
                    do { try store.removeWorkFromLibrary(work) }
                    catch { store.reportError(error.localizedDescription) }
                }
                Button("取消", role: .cancel) {}
            } message: { work in
                Text("移除「\(work.title)」及其库内资料。购买的原文件和已经保存的独立摘选会保留。")
            }
            .navigationDestination(item: $selectedTag) { tag in
                grid(store.works.filter(tag.contains))
                    .appPageBackground(.clear)
                    .appNavigationColors(contentTitle: true).navigationTitle(tag.title)
                    .toolbar(.visible, for: .navigationBar)
            }
            .navigationDestination(item: $selectedWork) { work in
                if work.libraryKind == .personal {
                    PersonalWorkInfoView(work: work, store: store)
                        .toolbar(.visible, for: .navigationBar)
                } else {
                    WorkDetailView(work: work, store: store)
                        .toolbar(.visible, for: .navigationBar)
                }
            }
            .task {
                #if DEBUG
                await runSeedIfRequested()
                // 调试：`-openFirstWork` 直接进入第一个作品，方便截图验证
                if CommandLine.arguments.contains("-openFirstWork"), let first = store.works.first {
                    selectedWork = first
                }
                // 调试：按曲目名定位作品并播放（验证字幕用）
                if let argIndex = CommandLine.arguments.firstIndex(of: "-openTrackNamed"),
                   CommandLine.arguments.count > argIndex + 1 {
                    let needle = CommandLine.arguments[argIndex + 1]
                    for work in store.works {
                        let tracks = store.tracks(for: work)
                        guard let track = tracks.first(where: { $0.fileName.contains(needle) }) else { continue }
                        selectedWork = work
                        let items = store.queueItems(for: work)
                        if let index = items.firstIndex(where: { $0.trackID == track.id }) {
                            player.play(items: items, startingAt: index)
                            // -miniOnly：只播放不弹播放页，用来检查底部标签栏
                            if !CommandLine.arguments.contains("-miniOnly") {
                                player.isPlayerSheetPresented = true
                            }
                        }
                        break
                    }
                }
                // 调试：直接打开统一导入入口。
                if CommandLine.arguments.contains("-importPreview") { showImport = true }
                #endif

            }
        }
        .personalWorkEditorPresentation(store: store)
        .accessibilityHidden(usesPorcelainMenu && headerMenu != nil)
        .overlay(alignment: .topLeading) {
            if let menu = headerMenu {
                GeometryReader { geometry in
                    let width = min(242, max(1, geometry.size.width - 32))
                    let anchor = menu == .library ? libraryTitleFrame : sortButtonFrame
                    let y = max(0, anchor.maxY - geometry.frame(in: .global).minY + 7)
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(coordinateSpace: .global) { point in
                                if usesPorcelainMenu, libraryTitleFrame.contains(point) {
                                    toggleHeaderMenu(.library)
                                } else if usesPorcelainMenu, section != .favorites, sortButtonFrame.contains(point) {
                                    toggleHeaderMenu(.sort)
                                } else {
                                    headerMenu = nil
                                }
                            }
                            .accessibilityHidden(true)
                        Group {
                            if usesPorcelainMenu {
                                PorcelainChoicePanel {
                                    if menu == .library { porcelainLibraries }
                                    else { porcelainSortChoices }
                                }
                            } else {
                                libraryChoices
                                    .background(AppTheme.textStyle(.regularMaterial, AppTheme.card), in: RoundedRectangle(cornerRadius: 22))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 22)
                                            .strokeBorder(AppTheme.textStyle(.primary.opacity(0.08), AppTheme.separator), lineWidth: 0.5)
                                    }
                                    .shadow(color: AppTheme.shadow.opacity(0.12), radius: 8, y: 4)
                                    .porcelainSurface()
                            }
                        }
                        .frame(width: width)
                        .frame(maxHeight: max(1, geometry.size.height - y - 8), alignment: .top)
                        .offset(x: menu == .library ? 16 : max(16, geometry.size.width - width - 20), y: y)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(menu == .library ? "libraryChoices" : "librarySortChoices")
                        .accessibilityAction(.escape) { headerMenu = nil }
                    }
                }
            }
        }
        .onChange(of: usesPorcelainMenu) { _, _ in headerMenu = nil }
    }

    private func toggleHeaderMenu(_ menu: HeaderMenu) {
        headerMenu = headerMenu == menu ? nil : menu
    }

    #if DEBUG
    /// 带 `-seedLibrary` 启动时，生成示例资料库并走一遍真实导入流程
    private func runSeedIfRequested() async {
        // 调试：导入 Documents 下的测试文件夹（验证字幕自动收集）
        if CommandLine.arguments.contains("-importTestFolder"),
           let documents = try? FileManager.default.url(
               for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
           ) {
            let url = documents.appendingPathComponent("字幕导入测试", isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                await store.importFolder(url: url, grouping: .singleWork)
            }
            return
        }
        if CommandLine.arguments.contains("-seedFlat") {
            if let root = try? DebugSeed.makeFlatOnlyFolder() {
                await store.importFolder(url: root, grouping: .automatic)
            }
            return
        }
        guard CommandLine.arguments.contains("-seedLibrary") else { return }
        do {
            let root = try DebugSeed.makeSampleLibrary()
            await store.importFolder(url: root)
        } catch {
            store.reportError("示例库生成失败：\(error.localizedDescription)")
        }
    }

    #endif

    /// Only the home screen owns this header. Pushed screens keep their native
    /// navigation bar and safe-area geometry, without inheriting the 8pt inset.
    private var libraryHomeHeader: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            libraryMenu
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            libraryHeaderActions
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
        .frame(minHeight: 44)
        .padding(.leading, 24)
        .padding(.trailing, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("libraryHomeHeader")
    }

    @ViewBuilder private var libraryHeaderActions: some View {
        if AppTheme.isPurple {
            libraryHeaderActionContent.background(AppTheme.surface, in: Capsule())
        } else if #available(iOS 26.0, *) {
            let glass: Glass = AppTheme.usesCustomPalette ? .regular.tint(AppTheme.surface.opacity(0.45)) : .regular
            libraryHeaderActionContent
                .glassEffect(glass.interactive(), in: Capsule())
        } else {
            libraryHeaderActionContent
                .background(.regularMaterial, in: Capsule())
        }
    }

    private var libraryHeaderActionContent: some View {
        HStack(spacing: !isPersonal && section == .works ? 4 : 12) {
            if collectionArrangement.isEditing {
                Button("完成") { collectionArrangement.finish() }
                    .foregroundStyle(AppTheme.textStyle(.foreground, usesPorcelainMenu ? AppTheme.emphasisInk : AppTheme.titleInk))
                    .frame(height: 44)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("collectionArrangementDone")
            } else {
                Button {
                    isSearching.toggle()
                    searchFocused = isSearching
                    if !isSearching { store.searchText = "" }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("搜索作品")
                .accessibilityIdentifier("librarySearch")
                if section != .favorites { sortMenu }
                if !isPersonal && section == .works { collectionDisplayToggle }
                Button { showImport = true } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("导入作品")
                .accessibilityIdentifier("libraryImport")
            }
        }
        .font(.system(size: 17))
        .imageScale(.large)
        .buttonStyle(.plain)
        .foregroundStyle(headerIconColor)
    }

    private var collectionDisplayToggle: some View {
        Button {
            // A display choice changes no library sort, filter or saved order.
            // Clear only an unfinished drag before replacing its visual slots.
            collectionArrangement.finish()
            collectionGridFrames = [:]
            collectionDisplayRaw = collectionDisplay.toggled.rawValue
        } label: {
            Image(systemName: collectionDisplay == .covers ? "list.bullet" : "square.grid.2x2")
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(collectionDisplay == .covers ? L10n.text("切换为横向列表") : L10n.text("切换为封面卡片"))
        .accessibilityValue(collectionDisplay == .covers ? L10n.text("封面卡片") : L10n.text("横向列表"))
        .accessibilityIdentifier("collectionDisplayToggle")
    }

    private var libraryMenu: some View {
        Button { toggleHeaderMenu(.library) } label: {
            VStack(spacing: -2) {
                Text(store.currentLibrary.displayName)
                    .font(.title.bold())
                    .foregroundStyle(AppTheme.textStyle(.primary, AppTheme.libraryTitleInk))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .regular))
                    .rotationEffect(.degrees(headerMenu == .library ? 180 : 0))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: headerMenu)
            }
            .foregroundStyle(headerIconColor)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .imageScale(.large)
        // Measure inside the visual offset so the menu follows the title's
        // global touch-area frame rather than an unshifted outer layout box.
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { frame in
            libraryTitleFrame = frame
        }
        .offset(y: 5)
        .accessibilityLabel("切换媒体库")
        .accessibilityValue(store.currentLibrary.displayName)
        .accessibilityIdentifier("librarySwitcher")
    }

    private var libraryChoices: some View {
        VStack(spacing: 0) {
            ForEach([MediaLibraryKind.collection, .personal], id: \.self) { library in
                Button {
                    headerMenu = nil
                    switchLibrary(library)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark")
                            .opacity(store.currentLibrary == library ? 1 : 0)
                            .frame(width: 16)
                        Text(library.displayName)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(AppTheme.primaryText)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(store.currentLibrary == library ? .isSelected : [])
                .accessibilityIdentifier("libraryMode-\(library == .personal ? "personal" : "collection")")
            }
        }
    }

    private func switchLibrary(_ library: MediaLibraryKind) {
        section = .works
        selectedTag = nil
        selectedWork = nil
        store.setCurrentLibrary(library)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.secondaryText)
            TextField(searchPrompt, text: $store.searchText)
                .focused($searchFocused)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
                .accessibilityIdentifier("librarySearchInput")
            if !store.searchText.isEmpty {
                Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(AppTheme.secondaryText).accessibilityLabel("清除搜索")
            }
        }
        .padding(10).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var sortMenu: some View {
        Group {
            if usesPorcelainMenu {
                Button { toggleHeaderMenu(.sort) } label: { sortIcon }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sortButtonFrame = $0 }
            } else {
                Menu {
                    Picker("排序", selection: $store.sortOrder) {
                        ForEach(WorkSortOrder.allCases, id: \.self) { order in Text(order.displayName).tag(order) }
                    }
                    Picker("筛选", selection: $store.filter) {
                        ForEach(Self.visibleFilters, id: \.self) { item in Text(item.displayName).tag(item) }
                    }
                } label: { sortIcon }
            }
        }
        .accessibilityLabel("排序与筛选")
        .accessibilityIdentifier("librarySortFilter")
        .onChange(of: store.sortOrder) { _, _ in store.applySearchAndSort() }
        .onChange(of: store.filter) { _, _ in store.applySearchAndSort() }
    }

    private var sortIcon: some View {
        Image(systemName: "line.3.horizontal.decrease.circle")
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    @ViewBuilder private var porcelainLibraries: some View {
        ForEach([MediaLibraryKind.collection, .personal], id: \.self) { library in
            PorcelainChoiceRow(title: library.displayName, selected: store.currentLibrary == library, minHeight: 48) {
                headerMenu = nil
                switchLibrary(library)
            }
            .accessibilityIdentifier("libraryMode-\(library == .personal ? "personal" : "collection")")
        }
    }

    @ViewBuilder private var porcelainSortChoices: some View {
        ForEach(WorkSortOrder.allCases, id: \.self) { order in
            PorcelainChoiceRow(title: order.displayName, selected: store.sortOrder == order) {
                store.sortOrder = order
                headerMenu = nil
            }
            .accessibilityIdentifier("libraryOrder-\(order.rawValue)")
        }
        Rectangle().fill(PorcelainChoicePanelColors.edge)
            .frame(height: 1).padding(.horizontal, 9).padding(.vertical, 4)
            .accessibilityHidden(true)
        ForEach(Self.visibleFilters, id: \.self) { filter in
            PorcelainChoiceRow(title: filter.displayName, selected: store.filter == filter) {
                store.filter = filter
                headerMenu = nil
            }
            .accessibilityIdentifier("libraryFilter-\(filter.displayName)")
        }
    }

    private var recentCreators: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(store.recentCreators) { creator in
                    NavigationLink {
                        CreatorProfileView(creatorID: creator.id, store: store)
                            .toolbar(.visible, for: .navigationBar)
                    } label: {
                        VStack(spacing: 5) {
                            CreatorAvatarView(path: store.creatorAvatarPath(creator), name: creator.name, size: 46)
                            Text(creator.name).font(.caption2).lineLimit(1).frame(width: 64)
                        }.foregroundStyle(AppTheme.primaryText)
                    }.buttonStyle(.plain)
                    .accessibilityIdentifier("recentCreator-\(creator.id)")
                }
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .accessibilityIdentifier("recentCreators")
    }

    @ViewBuilder private var browsingContent: some View {
        if section == .creators {
            creatorList
        } else if store.works.isEmpty {
            if store.searchText.isEmpty && store.filter == .all { emptyState }
            else { ContentUnavailableView("没有符合条件的作品", systemImage: "magnifyingglass") }
        } else if section == .works {
            if isPersonal { personalWorks }
            else { grid(store.works) }
        } else {
            LibraryTagView(section: section == .circles ? .circles : .performers, works: store.works) { selectedTag = $0 }
        }
    }

    private var creatorList: some View {
        let displayed = store.creators
        return List {
            HStack {
                Button("新建创作者", systemImage: "person.badge.plus") { showCreatorEditor = true }
                    .disabled(orderingCreators)
                    .accessibilityIdentifier("newCreator")
                Spacer()
                Button(orderingCreators ? L10n.text("完成") : L10n.text("调整顺序")) { orderingCreators.toggle() }
                    .disabled(displayed.count < 2 && !orderingCreators)
                    .accessibilityIdentifier("creatorOrderToggle")
            }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)
                .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                    dimensions[.leading] + 48
                }
                .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                    dimensions[.trailing] - 8
                }
                .porcelainPlainRow()
            ForEach(displayed) { creator in
                NavigationLink {
                    CreatorProfileView(creatorID: creator.id, store: store)
                        .toolbar(.visible, for: .navigationBar)
                } label: {
                    HStack(spacing: 12) {
                        CreatorAvatarView(path: store.creatorAvatarPath(creator), name: creator.name, size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(creator.name).foregroundStyle(AppTheme.primaryText)
                            if !creator.note.isEmpty {
                                Text(creator.note).font(.caption).foregroundStyle(AppTheme.secondaryText).lineLimit(1)
                            }
                        }
                    }.padding(.vertical, 10)
                }
                .accessibilityIdentifier("creator-\(creator.id)")
                .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                    dimensions[.leading] + 68
                }
                .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                    dimensions[.trailing] - 8
                }
                .porcelainPlainRow()
            }
            .onMove { source, destination in
                let original = displayed.map { String($0.id) }
                var ids = original
                ids.move(fromOffsets: source, toOffset: destination)
                do { try store.orderDirectory(.creators, ids: ids, visibleIDs: original) }
                catch { creatorOrderError = error.localizedDescription }
            }
        }.listStyle(.plain)
            .porcelainListBackground(AppTheme.card)
            .environment(\.editMode, .constant(orderingCreators ? .active : .inactive))
            .onDisappear { orderingCreators = false }
            .alert("调整顺序", isPresented: Binding(get: { creatorOrderError != nil }, set: { if !$0 { creatorOrderError = nil } })) {
                Button("好") { creatorOrderError = nil }
            } message: { Text(creatorOrderError ?? "") }
    }

    private var personalWorks: some View {
        let displayedWorks = store.works
        let visibleIDs = displayedWorks.map(\.id)
        return ScrollView {
            LazyVStack(spacing: 12) {
                if store.sortOrder == .custom { MediaWorkOrderingHint() }
                ForEach(displayedWorks) { work in
                    PersonalWorkCardView(work: work, store: store,
                        onShowDetails: { selectedWork = work },
                        onRemove: { pendingRemoval = work },
                        onMoveUp: mediaWorkMoveAction(work: work, offset: -1, visibleIDs: visibleIDs, store: store, session: workDrag),
                        onMoveDown: mediaWorkMoveAction(work: work, offset: 1, visibleIDs: visibleIDs, store: store, session: workDrag))
                        .modifier(MediaWorkReordering(work: work, visibleIDs: visibleIDs, store: store, session: workDrag))
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(AppTheme.isPurple ? .clear : AppTheme.background)
        .accessibilityIdentifier("personalWorkList")
        .onChange(of: visibleIDs) { _, _ in workDrag.invalidate() }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        ScrollView {
        ContentUnavailableView {
            Label("还没有导入作品", systemImage: "music.note.list")
        } description: {
            Text(isPersonal ? L10n.text("选择单个音频、文件夹或 ZIP，保存作品并指定创作者。") : L10n.text("选择作品文件夹或 ZIP，App 会扫描曲目、封面和台本。"))
        } actions: {
            Button("导入作品") { showImport = true }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)

            #if DEBUG
            NavigationLink("运行内核自检") {
                CoreCheckView()
                    .toolbar(.visible, for: .navigationBar)
            }
            .font(.footnote)
            #endif
        }
        .padding(.bottom, 32)
        }
    }

    // MARK: - 封面墙

    private func grid(_ works: [WorkRecord]) -> some View {
        let visibleIDs = works.map(\.id)
        let displayed = collectionArrangement.displayedWorks(works)
        return GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 12) {
                    if store.sortOrder == .custom {
                        ZStack(alignment: .leading) {
                            // Reserve the existing guidance height so feedback
                            // cannot move grid slots as the next drag begins.
                            Label(collectionArrangement.isEditing ? L10n.text("拖动作品调整位置，松手保存") : L10n.text("长按作品进入整理模式"), systemImage: "hand.draw")
                                .hidden().accessibilityHidden(true)
                            Label(collectionArrangement.hint, systemImage: "hand.draw")
                                .lineLimit(1).minimumScaleFactor(0.85)
                        }
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("mediaWorkOrderingHint")
                    }
                    LazyVGrid(columns: collectionDisplay == .covers ? columns : [GridItem(.flexible(), spacing: 0)],
                              spacing: collectionDisplay == .covers ? 12 : 0) {
                        ForEach(Array(displayed.enumerated()), id: \.element.id) { slot, work in
                            Button {
                                if !collectionArrangement.isEditing { selectedWork = work }
                            } label: {
                                if collectionDisplay == .covers {
                                    WorkCardView(work: work).contentShape(Rectangle())
                                } else {
                                    CollectionWorkListRow(work: work, store: store)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("libraryWork-\(work.id)")
                            .modifier(CollectionCardArrangement(workID: work.id, visibleIDs: visibleIDs,
                                isCustom: store.sortOrder == .custom, session: collectionArrangement))
                            .onDrop(of: [CollectionWorkArrangement.type], delegate: CollectionGridDropDelegate(
                                session: collectionArrangement, store: store, visibleIDs: visibleIDs, slot: slot))
                            .background {
                                GeometryReader { cell in
                                    Color.clear.preference(key: CollectionGridFrames.self, value: [slot:
                                        cell.frame(in: .named(CollectionWorkArrangement.coordinateSpace))])
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                .contentShape(Rectangle())
                .coordinateSpace(name: CollectionWorkArrangement.coordinateSpace)
                .onPreferenceChange(CollectionGridFrames.self) { collectionGridFrames = $0 }
                .onDrop(of: [CollectionWorkArrangement.type], delegate: CollectionGridDropDelegate(
                    session: collectionArrangement, store: store, visibleIDs: visibleIDs, frames: collectionGridFrames))
            }
            .accessibilityIdentifier("libraryWorkGrid")
        }
        .background(AppTheme.painted(.clear, AppTheme.isPurple ? .clear : AppTheme.background))
        .toolbar {
            if collectionArrangement.isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { collectionArrangement.finish() }
                        .foregroundStyle(AppTheme.textStyle(.tint, AppTheme.emphasisInk))
                        .accessibilityIdentifier("collectionArrangementDone")
                }
            }
        }
        .onChange(of: visibleIDs) { _, _ in collectionArrangement.cancelDrag() }
        .onChange(of: collectionDisplayRaw) { _, _ in collectionArrangement.finish(); collectionGridFrames = [:] }
        .onDisappear {
            collectionArrangement.finish()
            collectionGridFrames = [:]
        }
    }

    // MARK: - 进度条

    /// 导入完成的提示文字（ViewBuilder 里不能写语句，所以拆到这里）
    static func summaryText(works: Int, tracks: Int, subtitles: Int, unmatched: Int, pdfSummary: String) -> String {
        var parts = [L10n.text("\(works) 个作品 / \(tracks) 首曲目")]
        if subtitles > 0 { parts.append(L10n.text("新增 ") + String(subtitles) + L10n.text(" 份字幕")) }
        if unmatched > 0 { parts.append(String(unmatched) + L10n.text(" 份字幕未收录")) }
        if !pdfSummary.isEmpty { parts.append(pdfSummary) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var progressBar: some View {
        switch store.phase {
        case .scanning(let found):
            banner(text: found == 0 ? L10n.text("正在扫描…") : L10n.text("已发现 \(found) 个文件，正在整理…"), spinner: true)
        case .saving(let current, let total):
            banner(text: L10n.text("正在写入数据库 \(current)/\(total)…"), spinner: true)
        case .done(let works, let tracks, let subtitles, let unmatched, let pendingPDFs):
            if works == 0 || unmatched > 0 || pendingPDFs > 0 {
                banner(text: Self.summaryText(works: works, tracks: tracks, subtitles: subtitles, unmatched: unmatched, pdfSummary: store.scriptImportSummary),
                       spinner: false, tint: unmatched > 0 || pendingPDFs > 0 ? .orange : AppTheme.secondary)
            }
        case .failed(let message):
            banner(text: message, spinner: false, tint: .red)
        case .idle:
            EmptyView()
        }
    }

    private func banner(text: String, spinner: Bool, tint: Color = AppTheme.accent) -> some View {
        HStack(spacing: 8) {
            if spinner {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: tint == .red ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(tint)
            }
            ScrollView { Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true) }
                .frame(maxHeight: 120)
            Spacer(minLength: 0)
            if !spinner {
                Button { store.clearPhase() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel("关闭")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

#Preview {
    LibraryView()
}
