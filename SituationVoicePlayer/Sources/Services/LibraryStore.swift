import Foundation
import AVFoundation
import Combine

/// 媒体库的状态中心：持有数据库、负责导入与加载。
@MainActor
final class LibraryStore: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning(found: Int)
        case saving(current: Int, total: Int)
        case done(works: Int, tracks: Int, subtitles: Int, unmatchedSubtitles: Int, pendingPDFs: Int)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .scanning, .saving: return true
            default: return false
            }
        }
    }

    /// 导入前的预览结果
    struct ImportPreview: Equatable {
        var workCount: Int = 0
        var trackCount: Int = 0
        var videoCount: Int = 0
        var titles: [String] = []
        var subtitleCount = 0
        var coverCount = 0
        var subtitleFiles: [String] = []
        var unmatchedFiles: [String] = []

        mutating func describeFiles(in works: [ScannedWork]) {
            coverCount = works.filter { $0.coverRelativePath != nil }.count
            var imported = Set<String>(), all = Set<String>()
            for work in works {
                all.formUnion(work.subtitlePaths)
                let paths = work.tracks.flatMap { $0.variants.map(\.filePath) }
                let matches = SubtitleSidecarFinder.importMatches(audioPaths: paths,
                    subtitlePaths: work.subtitlePaths, selectedAudioPaths: Set(work.tracks.map(\.filePath)))
                for selected in matches.values {
                    let pair = SubtitleSidecarFinder.importPair(for: selected, subtitlePaths: work.subtitlePaths)
                    for match in [pair.primary, pair.secondary].compactMap({ $0 }) {
                        let url = URL(fileURLWithPath: match.path)
                        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                              size <= 32 * 1024 * 1024,
                              let data = try? Data(contentsOf: url), let text = SubtitleTextDecoder.decode(data: data),
                              !SubtitleParser.parse(text, formatHint: match.format).cues.isEmpty else { continue }
                        imported.insert(match.path)
                    }
                }
            }
            subtitleCount = imported.count
            subtitleFiles = imported.sorted().map { URL(fileURLWithPath: $0).lastPathComponent }
            unmatchedFiles = all.subtracting(imported).sorted().map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        var errorMessage: String?

        var isEmpty: Bool { workCount == 0 }
    }

    @Published private(set) var works: [WorkRecord] = []
    @Published private(set) var currentLibrary: MediaLibraryKind
    @Published private(set) var creators: [CreatorRecord] = []
    @Published private(set) var recentCreators: [CreatorRecord] = []
    @Published private(set) var directoryOrderRevision: UInt = 0
    @Published private(set) var otherLibraryMatchCount = 0
    @Published private(set) var sources: [LibrarySource] = []
    @Published private(set) var favoriteGroups: [NamedCollection] = []
    @Published private(set) var favoriteMemberships: [Int64: Set<Int64>] = [:]
    @Published private(set) var favoriteWorks: [WorkRecord] = []
    @Published private(set) var playlistGroups: [SavedPlaylistGroup] = []
    @Published private(set) var playlistEntries: [SavedPlaylistEntry] = []
    @Published private(set) var scriptImportSummary = ""
    let removedAttachmentIDs = PassthroughSubject<Set<Int64>, Never>()
    let removedTrackIDs = PassthroughSubject<Set<Int64>, Never>()
    let importedSubtitleTracks = PassthroughSubject<Set<Int64>, Never>()
    let relinkedTrackPaths = PassthroughSubject<[Int64: String], Never>()
    let replacedAudioSources = PassthroughSubject<[Int64: PlaybackQueueItem], Never>()
    let renamedPersonalAudio = PassthroughSubject<(workID: Int64, trackID: Int64, title: String), Never>()
    let relinkedAttachmentPaths = PassthroughSubject<[Int64: String], Never>()
    private(set) var fileRelinkRevision: UInt = 0
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var contentRevision: UInt = 0
    @Published private(set) var statsRevision: UInt = 0
    @Published var searchText: String = ""
    @Published var sortOrder: WorkSortOrder {
        didSet {
            guard !isRestoringLibrarySort, sortOrder != oldValue else { return }
            if sortOrder == .custom, !workOrderPreferences.hasCustomOrder(for: currentLibrary) {
                customSeedSort[currentLibrary] = oldValue
            }
            workOrderPreferences.setSelectedSort(sortOrder, for: currentLibrary)
            if sortOrder == .custom {
                do {
                    if let complete = try loadCustomCatalog(for: currentLibrary) {
                        applyCustomOrder(complete.map(\.id), to: currentLibrary)
                    }
                } catch { phase = .failed(InterfaceLocalization.text("读取作品顺序失败：\(error.localizedDescription)")) }
            }
        }
    }
    @Published var filter: WorkFilter = .all

    private var playlist: PlaylistRepository?
    private(set) var repository: LibraryRepository?
    private(set) var subtitleRepository: SubtitleRepository?
    private(set) var readingPositions: ReadingPositionRepository?
    let readingSessionHandoff = ScriptReadingHandoff()
    let fileLinkStatus = WorkFileLinkStatusCache()
    private var documentsRoot: String = ""
    private var resolvedRoots: [Int64: String] = [:]
    private let defaults: UserDefaults
    private let workOrderPreferences: WorkOrderPreferences
    private let directoryOrderPreferences: DirectoryOrderPreferences
    private var isRestoringLibrarySort = false
    private var customSeedSort: [MediaLibraryKind: WorkSortOrder] = [:]
    private var customCatalogs: [MediaLibraryKind: [WorkRecord]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.directoryOrderPreferences = DirectoryOrderPreferences(defaults: defaults)
        let ordering = WorkOrderPreferences(defaults: defaults)
        self.workOrderPreferences = ordering
        let library = MediaLibraryKind(rawValue: defaults.string(forKey: "selectedMediaLibrary") ?? "") ?? .collection
        self.currentLibrary = library
        self.sortOrder = ordering.selectedSort(for: library)
    }

    // MARK: - 生命周期

    func bootstrap() {
        guard repository == nil else { return }
        do {
            let url = try Self.databaseURL()
            documentsRoot = url.deletingLastPathComponent().path
            let db = try SQLiteDatabase(path: url.path)
            try Self.backUpBeforeMigration(db)
            let repo = LibraryRepository(database: db)
            try repo.prepare()
            self.subtitleRepository = SubtitleRepository(database: db)
            self.readingPositions = ReadingPositionRepository(database: db)
            let playlist = PlaylistRepository(database: db)
            self.playlist = playlist
            self.repository = repo
            reload()
            // Old single excerpts can be recovered only while their source and
            // an active timed subtitle track still exist. Save that copy now so
            // later source deletion cannot take the recovered subtitles with it.
            for entry in playlistEntries where entry.isClip && !entry.isMerged {
                do { _ = try savedClipSubtitles(entryID: entry.id) }
                catch { DebugLog.write("clip-subtitle-backfill failed entry=\(entry.id): \(error.localizedDescription)") }
            }
            // 导出后、登记前若进程被中断，独立目录里可能留下无主片段。
            if let entries = try? playlist.entries() { cleanUnusedClips(entries: entries) }
        } catch {
            phase = .failed(InterfaceLocalization.text("打开数据库失败：\(error.localizedDescription)"))
        }
    }

    private static func backUpBeforeMigration(_ database: SQLiteDatabase) throws {
        guard let version = try database.queryInt("PRAGMA user_version"),
              (1...24).contains(version) else { return }
        let files = FileManager.default
        let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("UpgradeBackups", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = version == 24 ? "pre-subtitle-pins-v24.sqlite"
            : version == 23 ? "pre-player-cover-mode-v23.sqlite" : "pre-video-playlist-v\(version).sqlite"
        let snapshot = folder.appendingPathComponent(name)
        guard !files.fileExists(atPath: snapshot.path) else { return }
        let staging = folder.appendingPathComponent(".\(UUID().uuidString).sqlite")
        defer { try? files.removeItem(at: staging) }
        // SQLite includes committed WAL frames and publishes a single self-contained file.
        try database.execute("VACUUM INTO ?", [.text(staging.path)])
        try files.moveItem(at: staging, to: snapshot)
    }

    private static func databaseURL() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return documents.appendingPathComponent("hibiki.db")
    }

    /// 独立连接在后台统计或清理，避免大量字幕历史阻塞设置页；主连接继续在主线程使用。
    func subtitleHistoryCache(clear: Bool = false) async throws -> SubtitleHistoryCleanupSummary {
        guard subtitleRepository != nil else { throw LibraryEditingError.unavailable }
        let protected = try SubtitleQuickDraftStore(defaults: defaults).protectedVersionIDs()
        let path = try Self.databaseURL().path
        return try await Task.detached(priority: .utility) {
            let database = try SQLiteDatabase(path: path)
            defer { database.close() }
            let repository = SubtitleRepository(database: database)
            if clear { return try repository.cleanupUnpinnedHistory(protectingVersionIDs: protected) }
            return try repository.historyCleanupSummary(protectingVersionIDs: protected)
        }.value
    }

    // MARK: - 读取

    func reload() {
        guard let repository else { return }
        // Edits/imports may target another library. Its next read must not reuse
        // old creator assignments or cover metadata from a previous visit.
        customCatalogs = customCatalogs.filter { $0.key == currentLibrary }
        do {
            playlistGroups = try playlist?.groups() ?? []
            playlistEntries = try playlist?.entries() ?? []
            sources = try repository.sources(includeDisabled: true)
            rebuildRootCache()
            favoriteGroups = try playlist?.collections(.favorites) ?? []
            favoriteMemberships = try playlist?.favoriteMemberships() ?? [:]
            creators = orderedCreators(try repository.creators())
            recentCreators = try repository.recentCreators(limit: 12)
            if sortOrder == .custom, let complete = try loadCustomCatalog(for: currentLibrary) {
                favoriteWorks = complete.filter(\.favorite)
                if filter == .all, searchText.isEmpty {
                    works = complete
                } else {
                    let matching = try repository.works(filter: filter, sort: .custom,
                        searchText: searchText.isEmpty ? nil : searchText, libraryKind: currentLibrary)
                    let matchingIDs = Set(matching.map(\.id))
                    works = complete.filter { matchingIDs.contains($0.id) }
                }
            } else {
                favoriteWorks = try repository.works(filter: .favorite, sort: sortOrder, libraryKind: currentLibrary).map { decorate($0) }
                works = try repository.works(
                    filter: filter,
                    sort: sortOrder,
                    searchText: searchText.isEmpty ? nil : searchText,
                    libraryKind: currentLibrary
                ).map { decorate($0) }
            }
            otherLibraryMatchCount = searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 :
                try repository.works(filter: filter, searchText: searchText,
                                     libraryKind: currentLibrary == .collection ? .personal : .collection).count
            contentRevision &+= 1
        } catch {
            phase = .failed(InterfaceLocalization.text("读取媒体库失败：\(error.localizedDescription)"))
        }
    }

    func applySearchAndSort() { reload() }

    func setCurrentLibrary(_ library: MediaLibraryKind) {
        guard currentLibrary != library else { return }
        isRestoringLibrarySort = true
        currentLibrary = library
        sortOrder = workOrderPreferences.selectedSort(for: library)
        isRestoringLibrarySort = false
        defaults.set(library.rawValue, forKey: "selectedMediaLibrary")
        reload()
    }

    /// Resolves the full library only on ordinary reload/sort selection. A drag
    /// uses this cache, never queries or writes the database on every movement.
    private func loadCustomCatalog(for library: MediaLibraryKind) throws -> [WorkRecord]? {
        guard let repository else { return nil }
        let seed = customSeedSort[library] ?? .custom
        let complete = try repository.works(sort: seed, libraryKind: library).map { decorate($0) }
        let ids = workOrderPreferences.reconcile(allIDs: complete.map(\.id), for: library)
        customSeedSort[library] = nil
        let result = ordered(complete, by: ids)
        customCatalogs[library] = result
        return result
    }

    private func ordered(_ rows: [WorkRecord], by ids: [Int64]) -> [WorkRecord] {
        let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        return rows.sorted {
            let first = positions[$0.id] ?? Int.max, second = positions[$1.id] ?? Int.max
            return first == second ? $0.id < $1.id : first < second
        }
    }

    private func applyCustomOrder(_ ids: [Int64], to library: MediaLibraryKind) {
        if let complete = customCatalogs[library] { customCatalogs[library] = ordered(complete, by: ids) }
        guard library == currentLibrary else { return }
        works = ordered(works, by: ids)
        favoriteWorks = ordered(favoriteWorks, by: ids)
    }

    /// `visibleIDs` must be the exact ordered subset shown at drag start. Hidden
    /// search/tag/creator entries keep their slots in the complete library.
    @discardableResult
    func reorderWorks(_ orderedIDs: [Int64], visibleIDs: [Int64], library: MediaLibraryKind) -> Bool {
        guard library == currentLibrary, sortOrder == .custom,
              let complete = customCatalogs[library],
              let updated = workOrderPreferences.reordered(orderedIDs, visibleIDs: visibleIDs,
                  allIDs: complete.map(\.id), for: library) else { return false }
        applyCustomOrder(updated, to: library)
        // Published lists refresh cards/creator subsets. Metadata did not change,
        // so avoid a contentRevision broadcast that would requery player details.
        return true
    }

    @discardableResult
    func moveWork(_ workID: Int64, relativeTo targetID: Int64, after: Bool,
                  visibleIDs: [Int64], library: MediaLibraryKind) -> Bool {
        guard workID != targetID, visibleIDs.contains(workID), visibleIDs.contains(targetID) else { return false }
        var reordered = visibleIDs.filter { $0 != workID }
        guard let target = reordered.firstIndex(of: targetID) else { return false }
        reordered.insert(workID, at: target + (after ? 1 : 0))
        return reorderWorks(reordered, visibleIDs: visibleIDs, library: library)
    }

    func directoryOrder(_ ids: [String], scope: DirectoryOrderScope) -> [String] {
        directoryOrderPreferences.resolved(ids, scope: scope)
    }

    private func orderedCreators(_ values: [CreatorRecord]) -> [CreatorRecord] {
        let byID = Dictionary(uniqueKeysWithValues: values.map { (String($0.id), $0) })
        return directoryOrder(values.map { String($0.id) }, scope: .creators).compactMap { byID[$0] }
    }

    func orderDirectory(_ scope: DirectoryOrderScope, ids: [String], visibleIDs: [String]) throws {
        guard let repository else { throw DirectoryOrderError.staleOrder }
        let allIDs: [String]
        if scope == .creators {
            allIDs = try repository.creators().map { String($0.id) }
        } else {
            let section: LibrarySection = scope == .circles ? .circles : .performers
            let complete = try repository.works(filter: .all, sort: .title, libraryKind: .collection)
            var names = Set<String>()
            var hasMissing = false
            for work in complete {
                let values = LibraryTag.names(for: work, section: section)
                if values.isEmpty { hasMissing = true }
                names.formUnion(values)
            }
            allIDs = names.sorted { NaturalSort.compare($0, $1) }.map { LibraryTag.orderID(name: $0) }
                + (hasMissing ? [LibraryTag.orderID(name: nil)] : [])
        }
        try directoryOrderPreferences.reorder(ids, visibleIDs: visibleIDs, allIDs: allIDs, scope: scope)
        if scope == .creators { creators = orderedCreators(try repository.creators()) }
        directoryOrderRevision &+= 1
    }

    func creator(id: Int64?) -> CreatorRecord? { id.flatMap { id in creators.first { $0.id == id } } }
    func creatorAvatarPath(_ creator: CreatorRecord) -> String? { creator.avatarAssetPath.flatMap(WorkAssetImporter.path) }
    func creatorCoverPath(_ creator: CreatorRecord) -> String? { creator.effectiveCoverAssetPath.flatMap(WorkAssetImporter.path) }
    func works(forCreatorID id: Int64) -> [WorkRecord] {
        let personalSort = workOrderPreferences.selectedSort(for: .personal)
        if personalSort == .custom {
            if let cached = customCatalogs[.personal] { return cached.filter { $0.creatorID == id } }
            let complete = ((try? repository?.works(sort: .custom, libraryKind: .personal)) ?? []).map { decorate($0) }
            let order = workOrderPreferences.resolvedOrder(allIDs: complete.map(\.id), for: .personal)
            return ordered(complete, by: order).filter { $0.creatorID == id }
        }
        return ((try? repository?.works(sort: personalSort, libraryKind: .personal, creatorID: id)) ?? []).map { decorate($0) }
    }

    @discardableResult
    func saveCreator(_ creator: CreatorRecord, callProfile: CallProfile? = nil) throws -> Int64 {
        guard let repository else { throw LibraryEditingError.unavailable }
        let previous = try repository.creator(id: creator.id)
        let oldProfile = creator.id > 0 ? try repository.callProfile(ownerKind: .creator, id: creator.id) : nil
        let id = try repository.db.transaction {
            let id = try repository.saveCreator(creator)
            if let callProfile { try repository.saveCallProfile(callProfile, ownerKind: .creator, id: id) }
            return id
        }
        removeUnreferencedCallAssets([previous?.avatarAssetPath, previous?.coverAssetPath,
                                     oldProfile?.avatarAssetPath, oldProfile?.backgroundAssetPath].compactMap { $0 })
        reload()
        return id
    }

    func savePersonalMetadata(for work: WorkRecord, title: String, creatorID: Int64?,
                              callProfile: CallProfile? = nil, playerCoverMode: PlayerCoverMode? = nil) throws {
        guard let repository else { throw LibraryEditingError.unavailable }
        let old = try repository.callProfile(ownerKind: .work, id: work.id)
        let renamedTrackID = try repository.db.transaction {
            let id = try repository.savePersonalWorkMetadata(workID: work.id, title: title, creatorID: creatorID,
                                                            playerCoverMode: playerCoverMode)
            if let callProfile { try repository.saveCallProfile(callProfile, ownerKind: .work, id: work.id) }
            return id
        }
        removeUnreferencedCallAssets([old?.avatarAssetPath, old?.backgroundAssetPath].compactMap { $0 })
        reload()
        if let renamedTrackID {
            renamedPersonalAudio.send((work.id, renamedTrackID, title.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    func setImportPhase(_ value: Phase) { phase = value }
    func setImportSummary(_ value: String) { scriptImportSummary = value }

    func reportError(_ message: String) { phase = .failed(message) }
    func clearPhase() { phase = .idle }

    func finishFileRelink(_ paths: [Int64: String], attachmentPaths: [Int64: String] = [:]) {
        fileRelinkRevision &+= 1
        reload()
        relinkedTrackPaths.send(paths)
        relinkedAttachmentPaths.send(attachmentPaths)
    }

    func finishAudioSourceReplacement(_ fallback: PlaybackQueueItem) {
        fileRelinkRevision &+= 1
        reload()
        let updated = (try? work(id: fallback.workID)).flatMap { work in
            queueItems(for: work).first { $0.trackID == fallback.trackID && !$0.isSavedClip }
        } ?? fallback
        replacedAudioSources.send([fallback.trackID: updated])
    }

    // MARK: - 路径解析

    private func rebuildRootCache() {
        resolvedRoots.removeAll()
        var staleRootUpdates: [Int64: String] = [:]
        let fm = FileManager.default
        for source in sources {
            var resolved: String?
            if let bookmark = source.bookmark,
               let restored = try? FolderImporter.resolve(bookmark: bookmark) {
                if fm.fileExists(atPath: restored.url.path) { resolved = restored.url.path }
            }
            if resolved == nil, let stored = source.rootPath, fm.fileExists(atPath: stored) {
                resolved = stored
            }
            if resolved == nil, let stored = source.rootPath,
               let reanchored = LibraryPathResolver.reanchor(
                    storedRoot: stored, currentDocumentsRoot: documentsRoot
               ),
               fm.fileExists(atPath: reanchored) {
                resolved = reanchored
            }
            if let resolved { resolvedRoots[source.id] = resolved }
        }

        // 把重锚定后的路径持久化，避免重复存储源
        for (sourceID, newRoot) in staleRootUpdates {
            guard var source = sources.first(where: { $0.id == sourceID }) else { continue }
            source.rootPath = newRoot
            if let newID = try? repository?.saveSource(source) {
                if source.id == 0 { resolvedRoots[newID] = newRoot }
            }
        }
        if !staleRootUpdates.isEmpty {
            sources = (try? repository?.sources(includeDisabled: true)) ?? sources
        }
    }

    private func contentDirectory(for work: WorkRecord, root: String) -> String {
        LibraryPathResolver.workDirectory(root: root, workRelativePath: work.folderRelativePath,
            grouping: sources.first(where: { $0.id == work.sourceID })?.grouping ?? .automatic)
    }

    private func decorate(_ work: WorkRecord) -> WorkRecord {
        var copy = work
        if let relative = work.coverAssetPath {
            copy.resolvedCoverPath = WorkAssetImporter.path(for: relative)
        }
        if let root = resolvedRoots[work.sourceID] {
            let workAbsolute = contentDirectory(for: work, root: root)
            if copy.resolvedCoverPath == nil, let cover = work.coverPath, !cover.isEmpty {
                copy.resolvedCoverPath = LibraryPathResolver.join(root: workAbsolute, relative: cover)
            }
            if let script = work.scriptPath, !script.isEmpty {
                copy.resolvedScriptPath = LibraryPathResolver.join(root: workAbsolute, relative: script)
            }
        }
        if work.libraryKind == .personal, let author = creator(id: work.creatorID) {
            copy.resolvedCoverPath = creatorCoverPath(author) ?? creatorAvatarPath(author)
        }
        return copy
    }

    /// 附件沿用已导入目录；同源仅一部作品时兼容旧格式子目录的作品边界。
    func attachmentSource(for work: WorkRecord) -> WorkAttachmentSource? {
        guard let source = sources.first(where: { $0.id == work.sourceID }),
              let root = resolvedRoots[source.id] ?? source.rootPath else { return nil }
        let singleWork = (try? repository?.works(sourceID: source.id).count) == 1
        return WorkAttachmentSource(sourceRootPath: root, bookmark: source.bookmark,
            workRelativePath: work.folderRelativePath,
            includeSourceRootAttachments: source.grouping == .automatic && singleWork
                && WorkAttachmentFinder.isLegacyFormatFolder(work.folderRelativePath), grouping: source.grouping,
            retainedCompanionPaths: (try? repository?.attachmentRecords(workID: work.id))?
                .filter { $0.assetRelativePath == nil }.map { $0.attachment.relativePath } ?? [])
    }

    /// 曲目绝对路径：存储源根 → 作品目录 → 曲目（库里存的是相对作品目录）
    func resolveTrackPath(_ track: TrackRecord, work: WorkRecord) -> String? {
        if let relative = track.assetRelativePath { return WorkAssetImporter.path(for: relative) }
        guard let root = resolvedRoots[work.sourceID] else { return nil }
        let workAbsolute = contentDirectory(for: work, root: root)
        if let relative = track.relativePath, !relative.isEmpty {
            return LibraryPathResolver.join(root: workAbsolute, relative: relative)
        }
        if FileManager.default.fileExists(atPath: track.filePath) { return track.filePath }
        return LibraryPathResolver.join(root: workAbsolute, relative: track.fileName)
    }

    // MARK: - 单个作品 / 播放

    func work(id: Int64) throws -> WorkRecord? {
        guard let repository else { return nil }
        return try repository.work(id: id).map { decorate($0) }
    }

    func displayWorkTitle(for item: PlaybackQueueItem) -> String {
        if item.isSavedClip {
            // 合并音频可能来自多部作品，封面归属不能代表其作品名。
            return playlistEntries.first { $0.id == -item.trackID }?.workTitle ?? item.workTitle
        }
        return (try? repository?.work(id: item.workID))?.title ?? item.workTitle
    }

    func displayWorkSubtitle(for item: PlaybackQueueItem) -> String? {
        guard !item.isSavedClip, let work = try? repository?.work(id: item.workID) else { return item.subtitle }
        if work.libraryKind == .personal { return creator(id: work.creatorID)?.name }
        return work.subtitle.isEmpty ? nil : work.subtitle
    }

    /// 记录开始时保留归属，切歌或稍后保存都不会串到下一部作品。
    func listeningAttribution(for item: PlaybackQueueItem) -> PlayStatRow {
        var workID = item.workID
        if item.isSavedClip {
            let entry = playlistEntries.first { $0.id == -item.trackID }
            // 合并摘选的 workID 只用于封面，来源已移除的副本也无法可靠归属。
            workID = entry?.isMerged == false && entry?.trackID != nil ? (entry?.workID ?? 0) : 0
        }
        let work = workID > 0 ? try? repository?.work(id: workID) : nil
        return PlayStatRow(workID: workID, title: work?.title ?? (workID > 0 ? item.workTitle : nil),
                           seiyuuNames: work?.seiyuuNames, circleName: work?.circleName,
                           dateKey: "", seconds: 0, libraryKind: work?.libraryKind,
                           creatorID: work?.creatorID, creatorName: creator(id: work?.creatorID)?.name)
    }

    func recordListening(_ rows: [PlayStatRow], sessions: [ListeningSessionDelta] = []) throws {
        guard !rows.isEmpty || !sessions.isEmpty else { return }
        guard let repository else { throw LibraryEditingError.unavailable }
        try repository.recordListening(rows, sessions: sessions)
        statsRevision &+= 1
    }

    func listeningMonthKeys() throws -> [String] {
        guard let repository else { throw LibraryEditingError.unavailable }
        return try repository.listeningMonthKeys()
    }

    func listeningRows(period: StatPeriod, now: Date = Date()) throws -> [PlayStatRow] {
        guard let repository else { throw LibraryEditingError.unavailable }
        return try repository.listeningRows(period: period, now: now)
    }

    func listeningHistory(period: StatPeriod, limit: Int, now: Date = Date()) throws -> [ListeningHistoryEntry] {
        guard let repository else { throw LibraryEditingError.unavailable }
        return try repository.listeningHistory(period: period, limit: limit, now: now)
    }

    func coverPath(forWorkID id: Int64) -> String? {
        guard let work = try? work(id: id) else { return nil }
        return decorate(work).resolvedCoverPath
    }

    func originalCoverPath(for work: WorkRecord) -> String? {
        var original = work
        original.coverAssetPath = nil
        original.resolvedCoverPath = nil
        return decorate(original).resolvedCoverPath
    }

    func savePlaybackPosition(workID: Int64, trackID: Int64, positionMS: Int, durationMS: Int) {
        guard let repository else { return }
        try? repository.savePlaybackPosition(workID: workID, trackID: trackID, positionMS: positionMS, countAsPlay: false)
        if ResumePolicy.shouldMarkListened(positionMS: positionMS, durationMS: durationMS) {
            try? repository.setListened(true, workID: workID)
        }
        if let recent = try? repository.recentCreators(limit: 12), recent != recentCreators { recentCreators = recent }
    }

    func tracks(for work: WorkRecord) -> [TrackRecord] {
        guard let repository else { return [] }
        let list = (try? repository.tracks(workID: work.id)) ?? []
        return list.map { track in
            var copy = track
            copy.resolvedFilePath = resolveTrackPath(track, work: work)
            return copy
        }
    }

    /// 播放队列：顺序与界面分组显示一致
    func queueItems(for work: WorkRecord) -> [PlaybackQueueItem] {
        let tracks = Dictionary(uniqueKeysWithValues: self.tracks(for: work).map { ($0.id, $0) })
        return organizedSections(for: work).flatMap(\.items).compactMap { media in
            switch media {
            case .track(let original):
                guard let track = tracks[original.id], let path = track.resolvedFilePath, !path.isEmpty else { return nil }
                return PlaybackQueueItem(workID: work.id, trackID: track.id, workTitle: work.title,
                    trackTitle: track.displayTitle, subtitle: work.libraryKind == .personal ? creator(id: work.creatorID)?.name : work.subtitle,
                    filePath: path, fileType: track.fileType, durationMS: track.durationMS, category: track.category)
            case .attachment(let record):
                guard record.attachment.kind == .video else { return nil }
                // Missing media stays visible in the queue and fails explicitly when loaded.
                let grouping = sources.first(where: { $0.id == work.sourceID })?.grouping ?? .automatic
                let directory = resolvedRoots[work.sourceID].map { contentDirectory(for: work, root: $0) }
                    ?? (grouping == .filesAsWorks ? (work.folderPath as NSString).deletingLastPathComponent : work.folderPath)
                let path = record.assetRelativePath.flatMap(WorkAssetImporter.path)
                    ?? LibraryPathResolver.join(root: directory, relative: record.attachment.relativePath)
                return PlaybackQueueItem(workID: work.id, trackID: 0, workTitle: work.title,
                    trackTitle: record.attachment.fileName, subtitle: work.libraryKind == .personal ? creator(id: work.creatorID)?.name : work.subtitle,
                    filePath: path, fileType: (record.attachment.fileName as NSString).pathExtension,
                    attachmentID: record.id)
            }
        }
    }

    // MARK: - 播放列表

    private func clipsDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return support.appendingPathComponent("PlaylistClips", isDirectory: true)
    }

    private func cleanUnusedClips(entries: [SavedPlaylistEntry]) {
        let names = Set(entries.compactMap(\.clipFilename))
        guard let directory = try? clipsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                    includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "caf" && !names.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    func createPlaylistGroup(name: String, isClips: Bool) throws -> Int64 {
        guard let playlist else { throw PlaylistError.unavailable }
        let id = try playlist.createGroup(name: name, isClips: isClips)
        playlistGroups = try playlist.groups()
        return id
    }

    func collections(for kind: CollectionKind) -> [NamedCollection] {
        if kind == .favorites { return favoriteGroups }
        return playlistGroups.filter { $0.isClips == (kind == .clips) }
            .map { NamedCollection(id: $0.id, name: $0.name) }
    }

    @discardableResult
    func createCollection(_ kind: CollectionKind, name: String) throws -> Int64 {
        guard let playlist else { throw PlaylistError.unavailable }
        let id = try playlist.createCollection(kind, name: name)
        reload()
        return id
    }

    func renameCollection(_ kind: CollectionKind, id: Int64, name: String) throws {
        guard let playlist else { throw PlaylistError.unavailable }
        try playlist.renameCollection(kind, id: id, name: name)
        reload()
    }

    func orderCollections(_ kind: CollectionKind, ids: [Int64]) throws {
        guard let playlist else { throw PlaylistError.unavailable }
        try playlist.orderCollections(kind, ids: ids)
        reload()
    }

    func deleteCollection(_ kind: CollectionKind, id: Int64) throws {
        guard let playlist else { throw PlaylistError.unavailable }
        try playlist.deleteCollection(kind, id: id)
        reload()
    }

    func isWorkFavorite(id: Int64) -> Bool {
        !(favoriteMemberships[id] ?? []).isEmpty
    }

    func setFavoriteGroups(workID: Int64, groupIDs: Set<Int64>) throws {
        guard let playlist else { throw PlaylistError.unavailable }
        try playlist.setFavoriteGroups(workID: workID, groupIDs: groupIDs)
        reload()
    }

    func entryCoverPath(_ entry: SavedPlaylistEntry) -> String? {
        entry.workID.flatMap { coverPath(forWorkID: $0) }
    }

    func addWholeTrack(_ item: PlaybackQueueItem, groupID: Int64? = nil) throws {
        guard let playlist else { throw PlaylistError.unavailable }
        switch item.mediaID {
        case .attachment(let id):
            try playlist.addVideo(attachmentID: id, title: item.trackTitle, workTitle: item.workTitle, groupID: groupID)
        case .track(let id):
            try playlist.addWholeTrack(trackID: id, title: item.trackTitle, workTitle: displayWorkTitle(for: item), groupID: groupID)
        case nil:
            throw PlaylistError.missingTrack
        }
        playlistEntries = try playlist.entries()
    }

    func saveClip(_ item: PlaybackQueueItem, startMS: Int, endMS: Int, groupID: Int64? = nil) async throws {
        guard let playlist else { throw PlaylistError.unavailable }
        guard item.trackID > 0, let track = try repository?.track(id: item.trackID),
              let work = try work(id: track.workID),
              let path = resolveTrackPath(track, work: work) else { throw PlaylistError.missingTrack }

        // Capture before the audio export suspends: later source edits must not
        // change the subtitle version that accompanied this save operation.
        let sourceCues = try subtitleRepository?.activeCues(trackID: item.trackID) ?? []
        let sourceLabel = try subtitleRepository?.tracks(forTrackID: item.trackID).first(where: \.isActive)?.displayLabel
        let snapshot = ClipSubtitleSnapshot(cues: ClipSubtitleTimeline.crop(sourceCues, startMS: startMS, endMS: endMS),
                                            sourceLabel: sourceLabel ?? "摘选字幕")

        let fm = FileManager.default
        let filename = UUID().uuidString + ".caf"
        let temporary = fm.temporaryDirectory.appendingPathComponent(filename)
        defer { try? fm.removeItem(at: temporary) }
        try await AudioClipExporter.write(from: URL(fileURLWithPath: path), to: temporary,
                                          startMS: startMS, endMS: endMS)
        try commitClip(temporary) { filename in
            try playlist.addClip(trackID: item.trackID, title: item.trackTitle, workTitle: displayWorkTitle(for: item),
                                 startMS: startMS, endMS: endMS, filename: filename, groupID: groupID, subtitles: snapshot)
        }
        playlistEntries = try playlist.entries()
    }

    func mergeClips(_ entries: [SavedPlaylistEntry], title: String, groupID: Int64) async throws {
        guard let playlist else { throw PlaylistError.unavailable }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PlaylistCollectionError.blankName }
        guard entries.count >= 2, entries.allSatisfy(\.isClip) else { throw PlaylistCollectionError.invalidSelection }
        let directory = try clipsDirectory()
        let sources = try entries.map { entry -> URL in
            guard let filename = entry.clipFilename else { throw PlaylistCollectionError.invalidSelection }
            return directory.appendingPathComponent(filename)
        }
        let subtitlesBySegment = try entries.map { try savedClipSubtitles(entryID: $0.id) }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? fm.removeItem(at: temporary) }
        let output = try await AudioClipMerger.writeWithTimeline(sources: sources, to: temporary)
        let segments = zip(subtitlesBySegment, output.segmentDurationsMS).map {
            ClipSubtitleSegment(cues: $0, durationMS: $1)
        }
        let snapshot = ClipSubtitleSnapshot(cues: try ClipSubtitleTimeline.concatenate(segments), sourceLabel: "拼接摘选字幕")
        let first = entries[0]
        let sameWork = entries.allSatisfy { $0.workTitle == first.workTitle }
        try commitClip(temporary) { filename in
            try playlist.addMerged(title: name, workTitle: sameWork ? first.workTitle : "多部作品",
                                   coverWorkID: first.workID, durationMS: output.durationMS, filename: filename,
                                   groupID: groupID, subtitles: snapshot)
            return true
        }
        playlistEntries = try playlist.entries()
    }

    /// The saved timeline always starts at zero and remains independent of the
    /// original audio/subtitle files. Older merged clips have no retained source
    /// recipe, so their missing captions cannot be reconstructed reliably.
    func savedClipSubtitles(entryID: Int64) throws -> [SubtitleCue] {
        guard let playlist else { throw PlaylistError.unavailable }
        if let saved = try playlist.clipSubtitles(entryID: entryID) { return saved.cues }
        guard let entry = try playlist.entries().first(where: { $0.id == entryID }),
              entry.isClip, !entry.isMerged, let trackID = entry.trackID,
              let start = entry.startMS, let end = entry.endMS,
              let subtitleRepository else { return [] }
        let source = try subtitleRepository.activeCues(trackID: trackID)
        guard source.contains(where: \.hasTiming) else { return [] }
        let label = try subtitleRepository.tracks(forTrackID: trackID).first(where: \.isActive)?.displayLabel
        let snapshot = ClipSubtitleSnapshot(cues: ClipSubtitleTimeline.crop(source, startMS: start, endMS: end),
                                            sourceLabel: label ?? "旧摘选字幕")
        try playlist.saveClipSubtitles(entryID: entryID, snapshot: snapshot, onlyIfMissing: true)
        return try playlist.clipSubtitles(entryID: entryID)?.cues ?? snapshot.cues
    }

    /// 文件搬入长期目录之后才登记；写库失败或组内重复时清理本次副本。
    private func commitClip(_ temporary: URL, insert: (String) throws -> Bool) throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        let directory = try clipsDirectory()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = temporary.lastPathComponent
        let final = directory.appendingPathComponent(filename)
        try fm.moveItem(at: temporary, to: final)
        var inserted = false
        defer { if !inserted { try? fm.removeItem(at: final) } }
        inserted = try insert(filename)
    }

    func removePlaylistEntry(_ entry: SavedPlaylistEntry) throws {
        guard let playlist else { throw PlaylistError.unavailable }
        try playlist.remove(id: entry.id)
        playlistEntries = try playlist.entries()
        if let name = entry.clipFilename {
            let url = try clipsDirectory().appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    func orderPlaylistEntries(groupID: Int64, ids: [Int64], expectedIDs: [Int64]) throws {
        guard let playlist else { throw PlaylistError.unavailable }
        try playlist.orderEntries(groupID: groupID, ids: ids, expectedIDs: expectedIDs)
        playlistEntries = try playlist.entries()
    }

    func movePlaylistEntry(_ entry: SavedPlaylistEntry, to groupID: Int64) throws {
        guard let playlist else { throw PlaylistError.unavailable }
        try playlist.moveEntry(id: entry.id, from: entry.groupID, to: groupID)
        playlistEntries = try playlist.entries()
    }

    func prepareClipExport(_ entry: SavedPlaylistEntry, format: SavedClipExportFormat = .mp3,
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> SavedClipFileExport {
        guard let playlist else { throw PlaylistError.unavailable }
        guard let saved = try playlist.entries().first(where: { $0.id == entry.id }),
              saved.isClip, saved.clipFilename == entry.clipFilename else { throw SavedClipExportError.missingClip }
        let directory = try clipsDirectory()
        let operation = Task.detached(priority: .userInitiated) {
            try SavedClipFileExport.prepare(entry: saved, clipsDirectory: directory, format: format, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: { operation.cancel() }
    }

    func playlistItem(for entry: SavedPlaylistEntry) -> PlaybackQueueItem? {
        if let attachmentID = entry.attachmentID {
            guard let workID = entry.workID, let work = try? work(id: workID) else { return nil }
            // The video player reopens external files under the source's security scope.
            return queueItems(for: work).first { $0.attachmentID == attachmentID }
        }
        let track = entry.trackID.flatMap { try? repository?.track(id: $0) }
        if let name = entry.clipFilename {
            guard let file = try? clipsDirectory().appendingPathComponent(name),
                  FileManager.default.fileExists(atPath: file.path) else { return nil }
            let title: String
            let duration: Int
            if let merged = entry.mergedMS {
                title = entry.title
                duration = merged
            } else if let first = entry.startMS, let last = entry.endMS {
                title = "\(entry.title) · 片段 \(SubtitleTime.clock(first))–\(SubtitleTime.clock(last))"
                duration = last - first
            } else { return nil }
            return PlaybackQueueItem(workID: entry.workID ?? 0, trackID: -entry.id, workTitle: entry.workTitle,
                                     trackTitle: title, filePath: file.path, fileType: "caf", durationMS: duration)
        }
        guard let track, let work = try? work(id: track.workID),
              let path = resolveTrackPath(track, work: work),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return PlaybackQueueItem(workID: work.id, trackID: track.id, workTitle: work.title, trackTitle: track.displayTitle,
                                 subtitle: work.subtitle.isEmpty ? nil : work.subtitle, filePath: path,
                                 fileType: track.fileType, durationMS: track.durationMS, category: track.category)
    }

    // MARK: - 分组

    func groupedTracks(for work: WorkRecord) -> [(category: WorkCategory, tracks: [TrackRecord])] {
        guard let repository else { return [] }
        let grouped = (try? repository.tracksGrouped(workID: work.id)) ?? []
        return grouped.map { section in
            (section.category, section.tracks.map { track in
                var copy = track
                copy.resolvedFilePath = resolveTrackPath(track, work: work)
                return copy
            })
        }
    }

    func categories(for work: WorkRecord) -> [WorkCategory] {
        guard let repository else { return WorkCategory.builtins }
        return (try? repository.categories(workID: work.id)) ?? WorkCategory.builtins
    }

    // MARK: - 手动调整

    func updateMetadata(for work: WorkRecord, circleName: String, seiyuuNames: [String]) throws {
        guard let repository else { throw LibraryEditingError.unavailable }
        try repository.updateWorkMetadata(workID: work.id, circleName: circleName, seiyuuNames: seiyuuNames)
        reload()
    }

    /// 图片已由编辑表复制并预览；提交失败时仍由编辑表持有，供重试或取消清理。
    func saveMetadata(for work: WorkRecord, title: String, rjCode: String? = nil, circleName: String,
                      seiyuuNames: [String], cover: WorkCoverUpdate, callProfile: CallProfile? = nil,
                      playerCoverMode: PlayerCoverMode? = nil) throws {
        guard let repository else { throw LibraryEditingError.unavailable }
        if case .replace(let relative) = cover {
            guard let path = WorkAssetImporter.path(for: relative), FileManager.default.fileExists(atPath: path) else {
                throw WorkAssetImportError.unreadableImage
            }
        }
        let old = try repository.work(id: work.id)?.coverAssetPath
        let oldProfile = try repository.callProfile(ownerKind: .work, id: work.id)
        try repository.db.transaction {
            try repository.updateWorkMetadata(workID: work.id, title: title, rjCode: rjCode, circleName: circleName,
                                              seiyuuNames: seiyuuNames, cover: cover, playerCoverMode: playerCoverMode)
            if let callProfile { try repository.saveCallProfile(callProfile, ownerKind: .work, id: work.id) }
        }
        removeUnreferencedCallAssets([old, oldProfile?.avatarAssetPath, oldProfile?.backgroundAssetPath].compactMap { $0 })
        reload()
    }

    func addAudioFiles(_ urls: [URL], to work: WorkRecord) async throws -> Int {
        if let invalid = urls.first(where: { WorkAttachmentFinder.kind(forExtension: $0.pathExtension) != nil }) {
            throw WorkAssetImportError.unreadableAudio(invalid.lastPathComponent)
        }
        return try await addMediaFiles(urls, to: work)
    }

    func changeCover(for work: WorkRecord, file: URL) async throws {
        let relative = try await Task.detached(priority: .userInitiated) {
            try WorkAssetImporter.copyCover(from: file)
        }.value
        try commitCover(relative, for: work)
    }

    func changeCover(for work: WorkRecord, imageData: Data) async throws {
        let relative = try await Task.detached(priority: .userInitiated) {
            try WorkAssetImporter.copyCover(data: imageData)
        }.value
        try commitCover(relative, for: work)
    }

    private func commitCover(_ relative: String, for work: WorkRecord) throws {
        do {
            try Task.checkCancellation()
            guard let repository else { throw LibraryEditingError.unavailable }
            let old = try repository.work(id: work.id)?.coverAssetPath
            try repository.updateWorkCover(workID: work.id, assetRelativePath: relative)
            if let old { removeUnreferencedCallAssets([old]) }
        } catch {
            WorkAssetImporter.remove(relative)
            throw error
        }
        reload()
    }

    func restoreOriginalCover(for work: WorkRecord) throws {
        guard let repository else { throw LibraryEditingError.unavailable }
        let old = try repository.work(id: work.id)?.coverAssetPath
        try repository.updateWorkCover(workID: work.id, assetRelativePath: nil)
        if let old { removeUnreferencedCallAssets([old]) }
        reload()
    }

    @discardableResult
    func addCategory(for work: WorkRecord, title: String) -> WorkCategory? {
        guard let repository else { return nil }
        let category = try? repository.addCustomCategory(workID: work.id, title: title)
        reload()
        return category
    }

    func renameCategory(for work: WorkRecord, key: String, title: String) {
        do { try renameCategoryTitle(for: work, key: key, title: title) }
        catch { reportError(error.localizedDescription) }
    }

    func renameCategoryTitle(for work: WorkRecord, key: String, title: String) throws {
        guard let repository else { throw LibraryEditingError.unavailable }
        try repository.renameCategory(workID: work.id, key: key, title: title)
        reload()
    }

    func removeCategory(for work: WorkRecord, key: String) {
        guard let repository else { return }
        try? repository.removeCustomCategory(workID: work.id, key: key)
        reload()
    }

    func moveTracks(_ trackIDs: [Int64], toCategory key: String?, in work: WorkRecord) {
        guard let repository, !trackIDs.isEmpty else { return }
        try? repository.setCategoryOverride(workID: work.id, trackIDs: trackIDs, key: key)
        reload()
    }

    /// 一次操作里同时改分组归属和顺序（拖放用），只刷新一次界面
    func applyManualMove(work: WorkRecord, trackIDs: [Int64], toCategory key: String, orderedTrackIDs: [Int64]) {
        guard let repository else { return }
        do {
            try repository.commitTrackMove(workID: work.id, trackIDs: trackIDs, toCategory: key,
                                            orderedTrackIDs: orderedTrackIDs)
        } catch { reportError(error.localizedDescription) }
        reload()
    }

    func commitTrackMove(work: WorkRecord, trackID: Int64, toCategory key: String,
                         orderedTrackIDs: [Int64]) throws {
        guard let repository else { throw LibraryEditingError.unavailable }
        try repository.commitTrackMove(workID: work.id, trackIDs: [trackID], toCategory: key,
                                        orderedTrackIDs: orderedTrackIDs)
        reload()
    }

    func saveTrackOrder(_ orderedTrackIDs: [Int64], in work: WorkRecord) {
        guard let repository else { return }
        try? repository.setTrackOrder(workID: work.id, orderedTrackIDs: orderedTrackIDs)
    }

    // MARK: - 导入

    func importFolder(url: URL, grouping: ScanOptions.Grouping = .automatic,
                      libraryKind: MediaLibraryKind = .collection, creatorID: Int64? = nil) async {
        guard let repository, let subtitleRepository else {
            phase = .failed(InterfaceLocalization.text("数据库尚未就绪"))
            return
        }

        guard !phase.isBusy else { return }
        scriptImportSummary = ""
        phase = .scanning(found: 0)

        do {
            let bookmark = try FolderImporter.makeBookmark(for: url)
            let displayName = FolderImporter.displayName(for: url)
            let rootPath = url.path

            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            DebugLog.write("开始导入「\(displayName)」，扫描目录 \(rootPath)，系统授权标记 \(accessed)")
            let files = try FolderImporter.enumerate(url: url, rootPath: rootPath)
            phase = .scanning(found: files.count)

            var scannedWorks = LibraryScanner.plan(
                files: files,
                sourceRoot: rootPath,
                options: ScanOptions(includeVideos: true, separateAudioFormats: true, grouping: grouping)
            )

            let knownSources = try repository.sources(includeDisabled: true)
            let canonicalRoot = url.resolvingSymlinksInPath().standardizedFileURL.path
            let existing = knownSources.first {
                $0.rootPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path } == canonicalRoot
            }
                ?? knownSources.first { source in
                    guard let bookmark = source.bookmark,
                          let restored = try? FolderImporter.resolve(bookmark: bookmark) else { return false }
                    defer { if restored.needsStop { restored.url.stopAccessingSecurityScopedResource() } }
                    return restored.url.resolvingSymlinksInPath().standardizedFileURL.path == canonicalRoot
                }
            // Validate the whole source before any source/work/attachment write.
            // A renamed or temporarily offline file must never trigger cascade deletion.
            let attachments = discoveredAttachments(files: files, works: scannedWorks, grouping: grouping, sourceID: existing?.id)
            if grouping == .filesAsWorks, let existing {
                scannedWorks = try retainingFileWorkReferences(scannedWorks, sourceID: existing.id, attachments: attachments)
            }
            if let existing {
                guard try repository.works(sourceID: existing.id).allSatisfy({ $0.libraryKind == libraryKind }) else {
                    throw WorkRelinkError.message(InterfaceLocalization.text("这个文件夹已导入另一媒体库，请切换到原媒体库后操作。已有作品没有改动。"))
                }
                try repository.validateSourceRescan(sourceID: existing.id, works: scannedWorks, attachments: attachments)
            }
            var source = existing ?? LibrarySource(name: displayName, type: .local, rootPath: rootPath)
            source.rootPath = rootPath
            source.name = displayName
            source.bookmark = bookmark
            source.enabled = true
            source.grouping = grouping
            let sourceID = try repository.saveSource(source)

            if grouping == .singleWork, !scannedWorks.isEmpty {
                // Selecting an entire work explicitly allows adding a previously removed work again.
                try repository.restoreExplicitWork(sourceID: sourceID, folder: ".")
            }
            let excluded = try repository.excludedWorkPaths(sourceID: sourceID)
            let planned = scannedWorks.filter {
                !excluded.contains(LibraryRepository.storageKey(relativePath: $0.folderRelativePath, absolutePath: $0.folderAbsolutePath))
            }
            phase = .saving(current: 0, total: planned.count)
            var savedTracks = 0
            var savedSubtitles = 0
            var pdfTrackIDs: Set<Int64> = []
            var sidecarTrackIDs: Set<Int64> = []
            var reviewPDFs: Set<String> = []
            let allSubtitles = Set(files.filter(\.isSubtitle).map(\.absolutePath))
            let outsideWorks = allSubtitles.subtracting(planned.flatMap(\.subtitlePaths))
            var unmatchedSubtitles = outsideWorks.count
            DebugLog.write("扫描到 \(files.count) 个文件，其中字幕 \(allSubtitles.count) 份")
            for path in outsideWorks.sorted() {
                DebugLog.write("不在本次作品目录内：\(path)")
            }

            for (index, scannedWork) in planned.enumerated() {
                let workID = try repository.upsertWork(
                    WorkRecord(
                        title: scannedWork.title,
                        rjCode: scannedWork.rjCode,
                        circleName: scannedWork.circleName,
                        seiyuuName: scannedWork.seiyuuName,
                        coverPath: scannedWork.coverRelativePath,
                        folderPath: scannedWork.folderAbsolutePath,
                        folderRelativePath: LibraryRepository.storageKey(
                            relativePath: scannedWork.folderRelativePath,
                            absolutePath: scannedWork.folderAbsolutePath
                        ),
                        sourceID: sourceID,
                        scriptPath: scannedWork.scriptRelativePath,
                        libraryKind: libraryKind, creatorID: libraryKind == .personal ? creatorID : nil
                    )
                )

                let tracks = scannedWork.tracks.filter { !$0.isVideo }.map { t in
                    TrackRecord(
                        workID: workID,
                        fileName: t.fileName,
                        filePath: t.filePath,
                        relativePath: t.relativePath,
                        fileType: t.fileType,
                        isVideo: t.isVideo,
                        title: t.title,
                        durationMS: nil,
                        fileSize: t.size,
                        fileMtime: t.modified,
                        category: t.category
                    )
                }
                try repository.replaceScannedAttachments(workID: workID, files: attachments[scannedWork.folderRelativePath] ?? [])
                try repository.replaceTracks(workID: workID, tracks: tracks)
                let persisted = try repository.tracks(workID: workID)
                savedTracks += persisted.filter { $0.assetRelativePath == nil }.count
                let result = try importSidecarSubtitles(
                    repository: subtitleRepository,
                    work: scannedWork,
                    tracks: persisted
                )
                savedSubtitles += result.trackIDs.count
                sidecarTrackIDs.formUnion(result.trackIDs)
                unmatchedSubtitles += result.notImported

                if scannedWork.scriptCandidates.contains(where: { ($0 as NSString).pathExtension.lowercased() == "pdf" }) {
                    let useSourceRoot = grouping == .automatic && scannedWorks.count == 1
                        && WorkAttachmentFinder.isLegacyFormatFolder(scannedWork.folderRelativePath)
                    let contentRoot = LibraryPathResolver.workDirectory(root: rootPath,
                        workRelativePath: scannedWork.folderRelativePath, grouping: grouping)
                    let attachmentRoot = URL(fileURLWithPath: useSourceRoot ? rootPath : contentRoot)
                    let hidden = Set(try repository.excludedFiles(workID: workID, kind: "attachment").map {
                        attachmentRoot.appendingPathComponent($0).resolvingSymlinksInPath().standardizedFileURL.path
                    })
                    let paths = scannedWork.scriptCandidates.filter {
                        !hidden.contains(URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path)
                    }
                    let pdfs = await Task.detached(priority: .userInitiated) {
                        AutomaticPDFScripts.read(paths: paths, sourceRoot: rootPath,
                                                 workRoot: contentRoot, tracks: persisted)
                    }.value
                    let saved = try await saveAutomaticScripts(pdfs, tracks: persisted, repository: subtitleRepository)
                    pdfTrackIDs.formUnion(saved.trackIDs)
                    reviewPDFs.formUnion(saved.forReview)
                }

                if index % 10 == 0 {
                    phase = .saving(current: index + 1, total: planned.count)
                }
            }

            _ = try repository.deleteWorks(
                sourceID: sourceID,
                notInFolderPaths: planned.map {
                    LibraryRepository.storageKey(
                        relativePath: $0.folderRelativePath,
                        absolutePath: $0.folderAbsolutePath
                    )
                }
            )

            var scriptMessages: [String] = []
            let videoCount = planned.reduce(0) { sum, work in
                sum + (attachments[work.folderRelativePath]?.filter { $0.kind == .video }.count ?? 0)
            }
            if videoCount > 0 { scriptMessages.append(InterfaceLocalization.text("\(videoCount) 个视频可在作品内打开")) }
            if !pdfTrackIDs.isEmpty { scriptMessages.append(InterfaceLocalization.text("PDF 台本配到 \(pdfTrackIDs.count) 条音轨")) }
            if !reviewPDFs.isEmpty {
                scriptMessages.append(InterfaceLocalization.text("\(reviewPDFs.count) 份 PDF 需在作品菜单手动配对"))
                for path in reviewPDFs.sorted() { DebugLog.write("PDF 待手动配对：\(path)") }
            }
            scriptImportSummary = scriptMessages.joined(separator: "；")
            reload()
            importedSubtitleTracks.send(pdfTrackIDs.union(sidecarTrackIDs))
            phase = .done(
                works: planned.count,
                tracks: savedTracks,
                subtitles: savedSubtitles,
                unmatchedSubtitles: unmatchedSubtitles,
                pendingPDFs: reviewPDFs.count
            )

            Task { await self.probeMissingDurations(sourceID: sourceID) }
        } catch {
            DebugLog.write("导入失败：\(error.localizedDescription)")
            phase = .failed(InterfaceLocalization.text("导入失败：\(error.localizedDescription)"))
        }
    }

    /// 从当前作品已获授权的目录重新取台本，不重新登记作品和音频。
    func rematchScripts(for work: WorkRecord) async throws -> WorkPDFMatchReport {
        guard let repository, let subtitleRepository else { throw LibraryEditingError.unavailable }
        let tracks = tracks(for: work)
        let expectedRelinkRevision = fileRelinkRevision
        let expectedSource = attachmentSource(for: work)
        var lease: WorkAttachmentDirectoryLease?
        var scanError: Error?
        if let source = expectedSource {
            do {
                let (directory, attachments) = try await Task.detached(priority: .userInitiated) {
                    try WorkAttachmentAccess.scan(source)
                }.value
                try Task.checkCancellation()
                guard fileRelinkRevision == expectedRelinkRevision,
                      let current = try repository.work(id: work.id), attachmentSource(for: current) == expectedSource else {
                    throw CancellationError()
                }
                try repository.validateAttachmentRescan(workID: work.id, files: attachments)
                try repository.replaceScannedAttachments(workID: work.id, files: attachments)
                lease = directory
            } catch let error as LibraryRelinkingError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch { scanError = error }
        }
        defer { withExtendedLifetime(lease) {} }
        let records = try repository.attachmentRecords(workID: work.id).filter { $0.attachment.kind == .pdf }
        if records.isEmpty, let scanError { throw scanError }
        var inputs: [Int64: AutomaticPDFScripts.Input] = [:]
        for record in records {
            if let asset = record.assetRelativePath, let path = WorkAssetImporter.path(for: asset) {
                // 自有文件使用 UUID 存储；解析时仍使用原文件名，并按附件 ID 区分同名文件。
                inputs[record.id] = .init(url: URL(fileURLWithPath: path),
                    relativePath: AutomaticPDFScripts.ownedSourceName(record), workRoot: nil)
            } else if record.assetRelativePath == nil, let lease,
                      let url = WorkAttachmentFinder.fileURL(for: record.attachment, in: lease.directory) {
                inputs[record.id] = .scanned(path: url.path, sourceRoot: lease.accessedURL.path,
                                             workRoot: lease.directory.path)
            }
        }
        let files = Array(inputs.values)
        let pdfs = await Task.detached(priority: .userInitiated) {
            AutomaticPDFScripts.read(inputs: files, tracks: tracks)
        }.value
        try Task.checkCancellation()
        guard fileRelinkRevision == expectedRelinkRevision,
                      let current = try repository.work(id: work.id), attachmentSource(for: current) == expectedSource else {
            throw CancellationError()
        }
        let result = try await saveAutomaticScripts(pdfs, tracks: tracks, repository: subtitleRepository) {
            guard self.fileRelinkRevision == expectedRelinkRevision,
                  let current = try repository.work(id: work.id), self.attachmentSource(for: current) == expectedSource else {
                throw CancellationError()
            }
        }
        let report = WorkPDFMatchReport(matchedCount: result.trackIDs.count, files: records.map { record in
            let path = inputs[record.id]?.relativePath
            let count = path.flatMap { result.savedCounts[$0] } ?? 0
            let note = path.flatMap { result.reasons[$0] }
            let detail: String
            if count > 0 {
                detail = InterfaceLocalization.text("已匹配 \(count) 条音轨。") + (note ?? "")
            } else {
                detail = note ?? InterfaceLocalization.text("无法读取该 PDF，请检查手机「文件」中的原文件。")
            }
            return WorkPDFMatchReport.File(record: record, detail: detail)
        })
        DebugLog.write("重新匹配「\(work.title)」：\(report.summary)")
        return report
    }

    private func saveAutomaticScripts(_ pdfs: AutomaticPDFScripts.Result, tracks: [TrackRecord],
                                      repository: SubtitleRepository, validate: (() throws -> Void)? = nil) async throws -> (trackIDs: Set<Int64>, forReview: Set<String>,
                                                                                 savedCounts: [String: Int], reasons: [String: String]) {
        var trackIDs: Set<Int64> = []
        var forReview = pdfs.forReview
        var reasons = pdfs.reasons
        var counts: [String: Int] = [:]
        let durations = await scriptDurations(for: pdfs.documents.flatMap(\.assignments), tracks: tracks)
        try Task.checkCancellation()
        try validate?()
        for document in pdfs.documents {
            do {
                counts[document.relativePath] = try repository.importScriptSections(document.assignments, fileName: document.relativePath,
                                                                                      automatically: true, durationsMS: durations)
                trackIDs.formUnion(document.assignments.compactMap(\.trackID))
            } catch {
                forReview.insert(document.relativePath)
                reasons[document.relativePath] = InterfaceLocalization.text("保存失败：\(error.localizedDescription)")
                DebugLog.write("台本保存失败：\(document.relativePath) · \(error.localizedDescription)")
            }
        }
        return (trackIDs, forReview, counts, reasons)
    }

    func saveManualScripts(_ files: [(name: String, rows: [ScriptImportAssignment])],
                           for tracks: [TrackRecord], activate: Bool) async throws -> Int {
        guard subtitleRepository != nil else { throw LibraryEditingError.unavailable }
        let path = try Self.databaseURL().path
        let durations = await scriptDurations(for: files.flatMap(\.rows), tracks: tracks)
        let workAttachments = try tracks.first.flatMap { try repository?.attachmentRecords(workID: $0.workID) } ?? []
        let oldNames = AutomaticPDFScripts.legacyNames(for: files.map(\.name), attachments: workAttachments)
        return try await Task.detached(priority: .userInitiated) {
            let db = try SQLiteDatabase(path: path)
            return try SubtitleRepository(database: db).importScriptFiles(files, activate: activate,
                                                                         durationsMS: durations, legacyNames: oldNames)
        }.value
    }

    /// 只在台本给出起点时读取音频时长。同一轨的多种译文共用一次读取。
    func scriptDurations(for assignments: [ScriptImportAssignment], tracks: [TrackRecord]) async -> [Int64: Int] {
        let timedIDs = Set(assignments.compactMap { row in
            row.section.lines.contains { $0.printedStartMS != nil } ? row.trackID : nil
        })
        var durations: [Int64: Int] = [:]
        for track in tracks where timedIDs.contains(track.id) {
            if let cached = track.durationMS, cached > 0 {
                durations[track.id] = cached
            } else if let ms = await Self.durationMS(of: track.resolvedFilePath ?? track.filePath), ms > 0 {
                durations[track.id] = ms
            }
        }
        return durations
    }

    /// 计算"如果按这个模式导入，会得到什么"，用于导入前预览。
    ///
    /// 枚举可能比较慢（大目录几万个文件），所以放到后台线程。
    func makePreview(url: URL, grouping: ScanOptions.Grouping) async -> ImportPreview {
        let rootPath = url.path
        let files: [ScannedFile]
        do {
            files = try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return try FolderImporter.enumerate(url: url, rootPath: rootPath)
            }.value
        } catch {
            DebugLog.write("预览读取失败：\(error.localizedDescription)")
            return ImportPreview(errorMessage: InterfaceLocalization.text("读取文件夹失败：\(error.localizedDescription)"))
        }

        guard !files.isEmpty else {
            return ImportPreview(errorMessage: InterfaceLocalization.text("这个文件夹里没有找到文件"))
        }

        let planned = LibraryScanner.plan(
            files: files,
            sourceRoot: rootPath,
            options: ScanOptions(includeVideos: true, separateAudioFormats: true, grouping: grouping)
        )

        if planned.isEmpty {
            return ImportPreview(
                errorMessage: InterfaceLocalization.text("没有找到音频或视频。请选择包含媒体文件的作品文件夹。")
            )
        }

        let media = planned.flatMap(\.tracks)
        let videoCount = discoveredAttachments(files: files, works: planned, grouping: grouping).values
            .reduce(0) { $0 + $1.filter { $0.kind == .video }.count }
        let trackCount = media.filter { !$0.isVideo }.count
        let titles = planned.prefix(5).map { $0.title }
        var preview = ImportPreview(workCount: planned.count, trackCount: trackCount, videoCount: videoCount, titles: titles)
        preview.describeFiles(in: planned)
        return preview
    }

    /// 使用本次扫描的路径，按作品匹配。未选用的音频版本也参与辨认，避免串用字幕。
    private func importSidecarSubtitles(
        repository: SubtitleRepository,
        work: ScannedWork,
        tracks: [TrackRecord]
    ) throws -> (trackIDs: Set<Int64>, notImported: Int) {
        var remaining = Set(work.subtitlePaths)
        DebugLog.write("作品目录 \(work.folderAbsolutePath)，发现 \(remaining.count) 份字幕")
        guard !remaining.isEmpty else { return ([], 0) }
        let audioPaths = work.tracks.flatMap { $0.variants.map(\.filePath) }
        let selectedPaths = Set(tracks.map(\.filePath))
        let matches = SubtitleSidecarFinder.importMatches(
            audioPaths: audioPaths, subtitlePaths: work.subtitlePaths, selectedAudioPaths: selectedPaths
        )
        func readSidecar(_ match: SidecarSubtitleMatch) -> [SubtitleCue]? {
            let url = URL(fileURLWithPath: match.path)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 32 * 1024 * 1024,
                  let data = try? Data(contentsOf: url), let text = SubtitleTextDecoder.decode(data: data) else { return nil }
            let cues = SubtitleParser.parse(text, formatHint: match.format).cues
            return cues.isEmpty ? nil : cues
        }
        var trackIDs: Set<Int64> = []
        for track in tracks {
            guard let selected = matches[track.filePath] else { continue }
            let pair = SubtitleSidecarFinder.importPair(for: selected, subtitlePaths: work.subtitlePaths)
            let match = pair.primary
            let label = (match.path as NSString).lastPathComponent
            let existing = try repository.tracks(forTrackID: track.id)
            if let previous = existing.first(where: { $0.kind == .sidecar && $0.label == label }) {
                remaining.remove(match.path)
                // Count an already imported translation without rewriting any edited version.
                if let secondary = pair.secondary, let primaryCues = readSidecar(match),
                   let secondaryCues = readSidecar(secondary) {
                    let expected = SubtitleTranslationMerger.merge(primary: primaryCues, secondary: secondaryCues)
                    let versions = try repository.versions(subtitleTrackID: previous.id)
                    for version in versions {
                        let saved = try repository.cues(versionID: version.id)
                        if saved.count == expected.count && zip(saved, expected).allSatisfy({
                            $0.text == $1.text && $0.translatedText == $1.translatedText &&
                            $0.startMS == $1.startMS && $0.endMS == $1.endMS
                        }) {
                            remaining.remove(secondary.path)
                            break
                        }
                    }
                }
                continue
            }
            do {
                guard let parsedCues = readSidecar(match) else { continue }
                var cues = parsedCues
                var translationPath: String?
                if let secondary = pair.secondary, let translation = readSidecar(secondary) {
                    if !translation.isEmpty {
                        cues = SubtitleTranslationMerger.merge(primary: cues, secondary: translation)
                        translationPath = secondary.path
                    }
                }
                try repository.createTrack(
                    trackID: track.id, kind: .sidecar, language: match.languageHint, label: label,
                    cues: cues, note: "导入作品时自动配对", activate: repository.shouldActivateNewSidecar(alongside: existing)
                )
                trackIDs.insert(track.id)
                remaining.remove(match.path)
                if let translationPath { remaining.remove(translationPath) }
                DebugLog.write("已写入 \(cues.count) 行：\(match.path) → \(track.fileName)")
            } catch {
                DebugLog.write("字幕读取或保存失败：\(match.path)，\(error.localizedDescription)")
            }
        }
        let variantOnly = Set(matches.filter { !selectedPaths.contains($0.key) }.map { $0.value.path })
        for path in remaining.sorted() {
            let reason = variantOnly.contains(path) ? "属于未选用的音频版本" : "未收录"
            DebugLog.write("\(reason)：\(path)")
        }
        DebugLog.write("「\(work.title)」新增 \(trackIDs.count) 份字幕，未收录 \(remaining.count) 份")
        return (trackIDs, remaining.count)
    }

    private func probeMissingDurations(sourceID: Int64) async {
        guard let repository else { return }
        do {
            let allWorks = try repository.works(sourceID: sourceID)
            var pending: [TrackRecord] = []
            for work in allWorks {
                let tracks = try repository.tracks(workID: work.id)
                pending.append(contentsOf: tracks.filter { $0.durationMS == nil && !$0.isVideo })
            }
            guard !pending.isEmpty else { return }

            let limit = 6
            var index = 0
            while index < pending.count {
                let batch = Array(pending[index..<min(index + limit, pending.count)])
                index += limit

                let durations = await withTaskGroup(of: (Int64, Int?).self) { group -> [(Int64, Int?)] in
                    for track in batch {
                        group.addTask {
                            let ms = await Self.durationMS(of: track.filePath)
                            return (track.id, ms)
                        }
                    }
                    var results: [(Int64, Int?)] = []
                    for await item in group { results.append(item) }
                    return results
                }
                try repository.updateTrackDurations(durations)
            }
            reload()
        } catch {
            // 时长探测失败不影响主流程
        }
    }

    nonisolated private static func durationMS(of path: String) async -> Int? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return Int(seconds * 1000)
    }

    // MARK: - 操作

    func toggleFavorite(_ work: WorkRecord) {
        guard let repository else { return }
        try? repository.setFavorite(!work.favorite, workID: work.id)
        reload()
    }

    func deleteWork(_ work: WorkRecord) {
        do { try removeWorkFromLibrary(work) }
        catch { reportError(InterfaceLocalization.text("移除作品失败：\(error.localizedDescription)")) }
    }

    var totalTracks: Int { works.reduce(0) { $0 + $1.trackCount } }
    var totalDurationMS: Int { works.reduce(0) { $0 + $1.totalDurationMS } }
}
