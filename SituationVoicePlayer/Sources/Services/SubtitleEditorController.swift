import Foundation

/// 字幕编辑：改文字、调时间、存新版本、导出。
///
/// 设计原则：**原版永不覆盖**。每次保存都新建一个版本，
/// 基线版本（version_no = 1）始终保留，随时能切回去。
@MainActor
final class SubtitleEditorController: ObservableObject {

    @Published private(set) var cues: [SubtitleCue] = []
    @Published private(set) var versions: [SubtitleVersionRecord] = []
    @Published private(set) var pinnedVersions: [SubtitleVersionRecord] = []
    @Published private(set) var activeVersionID: Int64?
    @Published private(set) var subtitleTrackID: Int64?
    @Published private(set) var hasChanges = false
    @Published var message: String?

    private var repository: SubtitleRepository?
    private var trackID: Int64?
    private var persistedVersionID: Int64?
    private var persistedCues: [SubtitleCue] = []

    func attach(repository: SubtitleRepository) {
        self.repository = repository
    }

    /// 载入某个曲目的字幕（当前生效版本）
    func load(trackID: Int64) {
        guard let repository else { return }
        self.trackID = trackID
        let tracks = (try? repository.tracks(forTrackID: trackID)) ?? []
        pinnedVersions = tracks.flatMap { (try? repository.pinnedVersions(subtitleTrackID: $0.id)) ?? [] }
        guard let active = tracks.first(where: \.isActive) else {
            cues = []
            versions = []
            subtitleTrackID = nil
            activeVersionID = nil
            hasChanges = false
            rememberPersistedCues()
            return
        }
        subtitleTrackID = active.id
        let list = (try? repository.versions(subtitleTrackID: active.id)) ?? []
        versions = list
        guard let latest = list.last else {
            cues = []
            activeVersionID = nil
            rememberPersistedCues()
            return
        }
        activeVersionID = latest.id
        var loaded = (try? repository.cues(versionID: latest.id)) ?? []
        if persistedVersionID == latest.id, persistedCues.count == loaded.count {
            for index in loaded.indices {
                var candidate = loaded[index]
                candidate.id = persistedCues[index].id
                if candidate == persistedCues[index] { loaded[index].id = candidate.id }
            }
        }
        cues = loaded
        hasChanges = false
        rememberPersistedCues()
    }

    private func rememberPersistedCues() {
        persistedVersionID = activeVersionID
        persistedCues = cues
    }

    /// 固定的是现有快照，不复制正文，也不切换当前正在使用的版本。
    @discardableResult
    func setVersionPinned(_ version: SubtitleVersionRecord, isPinned: Bool) -> Bool {
        guard let repository, let trackID else { return false }
        do {
            let sources = try repository.tracks(forTrackID: trackID)
            guard sources.contains(where: { $0.id == version.subtitleTrackID }),
                  try repository.setVersionPinned(version.id, isPinned: isPinned) else {
                message = InterfaceLocalization.text("版本已变更，请重新打开字幕版本。")
                return false
            }
            if let subtitleTrackID { versions = try repository.versions(subtitleTrackID: subtitleTrackID) }
            pinnedVersions = try sources.flatMap { try repository.pinnedVersions(subtitleTrackID: $0.id) }
            message = isPinned ? InterfaceLocalization.text("已固定版本") : InterfaceLocalization.text("已取消固定")
            return true
        } catch {
            message = InterfaceLocalization.text("未能更新版本固定状态：\(error.localizedDescription)")
            return false
        }
    }

    /// 来源栏中的固定快照可跨来源恢复；正文复制与来源切换在同一个事务中完成。
    @discardableResult
    func restorePinnedVersion(_ version: SubtitleVersionRecord) -> Bool {
        guard let repository, let trackID, !hasChanges,
              pinnedVersions.contains(where: { $0.id == version.id }) else { return false }
        if version.id == activeVersionID { return true }
        do {
            _ = try repository.restoreVersion(version.id, trackID: trackID)
            load(trackID: trackID)
            message = InterfaceLocalization.text("已恢复 v\(version.versionNo)，历史版本仍保留")
            return true
        } catch {
            message = InterfaceLocalization.text("恢复失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 当前字幕由最新版本决定。恢复历史时新建副本，避免仅切换内存后被播放器重载覆盖。
    @discardableResult
    func switchVersion(_ version: SubtitleVersionRecord) -> Bool {
        guard let repository, let trackID, let subtitleTrackID, version.subtitleTrackID == subtitleTrackID,
              versions.contains(where: { $0.id == version.id }), !hasChanges else { return false }
        if version.id == activeVersionID { return true }
        do {
            _ = try repository.restoreVersion(version.id, trackID: trackID)
            load(trackID: trackID)
            message = InterfaceLocalization.text("已恢复 v\(version.versionNo)，历史版本仍保留")
            return true
        } catch {
            message = InterfaceLocalization.text("恢复失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 编辑操作

    func setText(at index: Int, to text: String) {
        cues = CueEditor.settingText(cues, at: index, to: text)
        hasChanges = true
    }

    /// 快速改字只改文字；时间、置信度、说话人和自动结束状态全部保留。
    @discardableResult
    func applyTextEdit(at index: Int, text: String, translation: String?) -> Bool {
        guard cues.indices.contains(index) else { return false }
        cues[index].text = text
        cues[index].translatedText = translation
        hasChanges = true
        return true
    }

    /// 分隔线上的加号只建立空行，不替用户猜测内容或时间。
    @discardableResult
    func insertBlankCue(after index: Int) -> Int? {
        guard cues.indices.contains(index) || (cues.isEmpty && index == -1) else { return nil }
        let inserted = index + 1
        cues.insert(SubtitleCue(index: inserted, startMS: 0, endMS: 0, text: "", status: .untimed), at: inserted)
        cues = CueEditor.reindex(cues)
        hasChanges = true
        return inserted
    }

    /// 成功后才发布新行，失败时编辑快照和旧版保持原样。保留已有 UUID，列表无需整体重建。
    @discardableResult
    func insertAndSaveBlankCue(after index: Int) -> Int? {
        guard let repository, let activeVersionID, let subtitleTrackID,
              cues.indices.contains(index) || (cues.isEmpty && index == -1) else { return nil }
        do {
            let newVersion = try repository.insertBlankVersion(copying: activeVersionID, after: index,
                                                               pendingCues: hasChanges ? cues : nil)
            let inserted = index + 1
            var updated = cues
            updated.insert(SubtitleCue(index: inserted, startMS: 0, endMS: 0, text: "", status: .untimed), at: inserted)
            cues = CueEditor.reindex(updated)
            self.activeVersionID = newVersion
            hasChanges = false
            rememberPersistedCues()
            versions = (try? repository.versions(subtitleTrackID: subtitleTrackID)) ?? versions
            message = InterfaceLocalization.text("已添加空白字幕行")
            return inserted
        } catch {
            message = InterfaceLocalization.text("添加失败：\(error.localizedDescription)")
            return nil
        }
    }

    func setStart(at index: Int, to ms: Int) {
        cues = CueEditor.settingStart(cues, at: index, to: max(0, ms))
        hasChanges = true
    }

    func setEnd(at index: Int, to ms: Int) {
        cues = CueEditor.settingEnd(cues, at: index, to: max(0, ms))
        hasChanges = true
    }

    /// 在副本中建立草稿，时间验证通过后一次性替换；取消或重试不会多插一行。
    func applyEdit(at index: Int, inserting: Bool, text: String, translation: String?,
                   startMS: Int?, endMS: Int?, durationMS: Int?) -> Bool {
        var updated = cues
        if inserting {
            guard index > 0, cues.indices.contains(index - 1) else { return false }
            updated = CueEditor.insertEmpty(cues, after: index - 1)
        }
        guard updated.indices.contains(index) else { return false }
        if let startMS {
            guard let ranged = CueEditor.settingEditableRange(updated, at: index, startMS: startMS,
                                                                endMS: endMS, durationMS: durationMS) else { return false }
            updated = ranged
        } else {
            updated[index].startMS = 0
            updated[index].endMS = 0
            updated[index].status = .untimed
        }
        updated = CueEditor.settingText(updated, at: index, to: text)
        cues = CueEditor.settingTranslation(updated, at: index, to: translation)
        hasChanges = true
        return true
    }

    func nudge(at index: Int, by deltaMS: Int) {
        guard cues.indices.contains(index), cues[index].hasTiming else { return }
        let cue = cues[index]
        cues[index].startMS = max(0, cue.startMS + deltaMS)
        cues[index].endMS = max(cues[index].startMS + 100, cue.endMS + deltaMS)
        hasChanges = true
    }

    func nudgeAll(by deltaMS: Int) {
        cues = CueEditor.shiftAll(cues, by: deltaMS)
        hasChanges = true
    }

    func snapEnds() {
        cues = CueEditor.snapEndsToNextStart(cues)
        hasChanges = true
    }

    /// 在指定位置后面插入一句空字幕（时间取两句中间）
    @discardableResult
    func insertCue(after index: Int) -> Int? {
        guard !cues.isEmpty else {
            // 完全没有字幕时，从 0 秒开始建一句
            cues = [SubtitleCue(index: 0, startMS: 0, endMS: 2_000, text: "新字幕")]
            hasChanges = true
            return 0
        }
        let target = min(max(0, index), cues.count - 1)
        let current = cues[target]
        let start = current.endMS
        let end = start + 2_000
        cues = CueEditor.insertEmpty(cues, after: target)
        if cues.indices.contains(target + 1), current.hasTiming {
            cues[target + 1].startMS = start
            cues[target + 1].endMS = end
            cues[target + 1].text = "新字幕"
        }
        cues[target + 1].text = "新字幕"
        hasChanges = true
        return target + 1
    }

    func deleteCue(at index: Int) {
        guard cues.indices.contains(index) else { return }
        cues = CueEditor.delete(cues, at: [index])
        hasChanges = true
    }

    // MARK: - 保存

    /// 保存为新版本
    @discardableResult
    func saveAsNewVersion(note: String = "手工修正", durationMS: Int? = nil, resolveAutomaticEnds: Bool = true) -> Bool {
        guard let repository, let subtitleTrackID else { return false }
        guard hasChanges else {
            message = InterfaceLocalization.text("没有改动")
            return false
        }
        do {
            let savedCues = resolveAutomaticEnds ? CueEditor.resolvingAutomaticEnds(cues, durationMS: durationMS) : cues
            let versionID = try repository.insertVersion(
                subtitleTrackID: subtitleTrackID,
                note: note,
                isBaseline: false,
                cues: savedCues
            )
            activeVersionID = versionID
            cues = savedCues
            hasChanges = false
            rememberPersistedCues()
            if let refreshed = try? repository.versions(subtitleTrackID: subtitleTrackID) {
                versions = refreshed
                message = InterfaceLocalization.text("已保存为 v\(versions.last?.versionNo ?? 0)")
            } else {
                message = InterfaceLocalization.text("已保存，可重新打开查看版本列表。")
            }
            return true
        } catch {
            message = InterfaceLocalization.text("保存失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 恢复成基线版本
    @discardableResult
    func revertToBaseline() -> Bool {
        guard let baseline = versions.first(where: \.isBaseline) else { return false }
        return switchVersion(baseline)
    }

    // MARK: - 导出

    /// 菜单会在选格式前显示可写入的句数；只有已设起点的行才能导出为时间字幕。
    func exportTimedFile(format: SubtitleFormat, baseName: String) throws -> URL {
        let timed = cues.filter(\.hasTiming)
        guard !timed.isEmpty else { throw SubtitleFileError.noTimedLines }
        let content = SubtitleExporter.export(timed, format: format)
        return try writeExport(content, baseName: baseName, fileExtension: format.fileExtension)
    }

    func exportTextFile(baseName: String) throws -> URL {
        guard !cues.isEmpty else { throw SubtitleFileError.noLines }
        let content = cues.map { cue in
            let prefix = cue.speaker.map { "\($0)：" } ?? ""
            return prefix + cue.displayText
        }.joined(separator: "\n\n")
        return try writeExport(content, baseName: baseName, fileExtension: "txt")
    }

    private func writeExport(_ content: String, baseName: String, fileExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubtitleExports", isDirectory: true)
            .appendingPathComponent(String(subtitleTrackID ?? 0), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = SubtitleExporter.sanitizeFileName(baseName)
        let url = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private enum SubtitleFileError: LocalizedError {
    case noLines, noTimedLines
    var errorDescription: String? {
        switch self {
        case .noLines: return InterfaceLocalization.text("当前没有可以导出的台词。")
        case .noTimedLines: return InterfaceLocalization.text("请先为至少一句台词设置开始时间，也可以导出完整台本 TXT。")
        }
    }
}

/// 打字时可能自动换曲；独立保留尚未确认的文字，不能因页面重建丢掉。
struct SubtitleQuickDraft: Codable, Equatable {
    var trackID: Int64
    var versionID: Int64
    var index: Int
    var text: String
    var translation: String
}

struct SubtitleQuickDraftStore {
    var defaults: UserDefaults = .standard
    private let key = "subtitleQuickDrafts.v1"

    /// 读取、写入和历史清理共用完整解析；异常值不能被当成空草稿覆盖。
    private func readDrafts() throws -> [String: SubtitleQuickDraft] {
        guard let value = defaults.object(forKey: key) else { return [:] }
        guard let data = value as? Data else { throw CocoaError(.propertyListReadCorrupt) }
        let saved = try JSONDecoder().decode([String: SubtitleQuickDraft].self, from: data)
        guard saved.allSatisfy({ $0.key == String($0.value.trackID) && Self.isValid($0.value) }) else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return saved
    }

    private static func isValid(_ draft: SubtitleQuickDraft) -> Bool {
        draft.trackID > 0 && draft.versionID > 0 && draft.index >= 0
    }

    func draft(for trackID: Int64) -> SubtitleQuickDraft? { try? readDrafts()[String(trackID)] }

    /// 清理历史前必须完整解析；不能把损坏或未知格式误判为空草稿后删除其基准。
    func protectedVersionIDs() throws -> Set<Int64> {
        Set(try readDrafts().values.map(\.versionID))
    }

    func save(_ draft: SubtitleQuickDraft) throws {
        var values = try readDrafts()
        guard Self.isValid(draft) else { throw CocoaError(.propertyListReadCorrupt) }
        values[String(draft.trackID)] = draft
        let data = try JSONEncoder().encode(values)
        defaults.set(data, forKey: key)
    }

    func remove(for trackID: Int64) throws {
        var values = try readDrafts()
        guard values.removeValue(forKey: String(trackID)) != nil else { return }
        let data = try JSONEncoder().encode(values)
        defaults.set(data, forKey: key)
    }
}
