import Foundation

// MARK: - 版本

/// 一个字幕版本。
///
/// 为什么不是"直接改"：用户要求"能导出新版本"，而且 AI 原版必须永远留存
/// （改坏了能回去）。所以每次保存产生一个新版本，条目整份拷贝。
/// 两小时字幕约 2000 条，一份拷贝几十 KB，代价可以忽略。
public struct SubtitleVersion: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    /// 显示用版本号：1, 2, 3…
    public var number: Int
    /// 备注，例如 "手工修正 32 处"
    public var note: String
    /// 是否是 AI 原始版本（不可删除、不可覆盖）
    public var isBaseline: Bool
    public var createdAt: Date
    public var cues: [SubtitleCue]
    /// 这一版是从哪一版派生出来的（用于版本树）
    public var basedOn: UUID?

    public init(
        id: UUID = UUID(),
        number: Int,
        note: String = "",
        isBaseline: Bool = false,
        createdAt: Date = Date(),
        cues: [SubtitleCue],
        basedOn: UUID? = nil
    ) {
        self.id = id
        self.number = number
        self.note = note
        self.isBaseline = isBaseline
        self.createdAt = createdAt
        self.cues = cues
        self.basedOn = basedOn
    }

    public var summary: String {
        InterfaceLocalization.text("v\(number) · \(cues.count) 句") + (note.isEmpty ? "" : " · \(note)")
    }
}

// MARK: - 差异

public enum ChangedField: String, CaseIterable, Sendable {
    case text
    case translation
    case start
    case end
    case speaker
    case status
}

public struct CueChange: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case added
        case removed
        case modified
    }

    public var kind: Kind
    /// 在新版本里的下标（removed 时为新版本中的插入点）
    public var index: Int
    public var before: SubtitleCue?
    public var after: SubtitleCue?
    public var fields: Set<ChangedField>

    public init(
        kind: Kind, index: Int,
        before: SubtitleCue? = nil, after: SubtitleCue? = nil,
        fields: Set<ChangedField> = []
    ) {
        self.kind = kind
        self.index = index
        self.before = before
        self.after = after
        self.fields = fields
    }
}

/// 版本对比。
///
/// 优先按 UUID 配对（同一次编辑里 UUID 保持不变，最可靠）；
/// 如果两版的 UUID 完全没有交集（比如从外部重新导入了一个文件），
/// 退化为按位置配对 —— 这种情况只能报告"第 N 条变了"。
public enum CueDiffer {

    public static func diff(_ old: [SubtitleCue], _ new: [SubtitleCue]) -> [CueChange] {
        let oldIDs = Set(old.map(\.id))
        let newIDs = Set(new.map(\.id))
        let shared = oldIDs.intersection(newIDs).count
        let smaller = max(1, min(old.count, new.count))
        let useIdentity = Double(shared) / Double(smaller) >= 0.5

        return useIdentity ? diffByIdentity(old, new) : diffByPosition(old, new)
    }

    static func diffByIdentity(_ old: [SubtitleCue], _ new: [SubtitleCue]) -> [CueChange] {
        var oldByID: [UUID: SubtitleCue] = [:]
        for cue in old where oldByID[cue.id] == nil { oldByID[cue.id] = cue }

        var changes: [CueChange] = []
        var seen = Set<UUID>()

        for (idx, cue) in new.enumerated() {
            seen.insert(cue.id)
            guard let previous = oldByID[cue.id] else {
                changes.append(CueChange(kind: .added, index: idx, after: cue))
                continue
            }
            let fields = changedFields(between: previous, and: cue)
            if !fields.isEmpty {
                changes.append(
                    CueChange(kind: .modified, index: idx, before: previous, after: cue, fields: fields)
                )
            }
        }

        for (idx, cue) in old.enumerated() where !seen.contains(cue.id) {
            changes.append(CueChange(kind: .removed, index: idx, before: cue))
        }

        return changes.sorted { $0.index < $1.index }
    }

    static func diffByPosition(_ old: [SubtitleCue], _ new: [SubtitleCue]) -> [CueChange] {
        var changes: [CueChange] = []
        let common = min(old.count, new.count)
        for idx in 0..<common {
            let fields = changedFields(between: old[idx], and: new[idx])
            if !fields.isEmpty {
                changes.append(
                    CueChange(kind: .modified, index: idx, before: old[idx], after: new[idx], fields: fields)
                )
            }
        }
        if new.count > old.count {
            for idx in common..<new.count {
                changes.append(CueChange(kind: .added, index: idx, after: new[idx]))
            }
        } else if old.count > common {
            for idx in common..<old.count {
                changes.append(CueChange(kind: .removed, index: idx, before: old[idx]))
            }
        }
        return changes
    }

    public static func changedFields(between a: SubtitleCue, and b: SubtitleCue) -> Set<ChangedField> {
        var fields = Set<ChangedField>()
        if a.text != b.text { fields.insert(.text) }
        if (a.translatedText ?? "") != (b.translatedText ?? "") { fields.insert(.translation) }
        if a.startMS != b.startMS { fields.insert(.start) }
        if a.endMS != b.endMS { fields.insert(.end) }
        if (a.speaker ?? "") != (b.speaker ?? "") { fields.insert(.speaker) }
        if a.status != b.status { fields.insert(.status) }
        return fields
    }

    /// 人话描述一处改动，用于"版本对比"列表
    public static func describe(_ change: CueChange) -> String {
        switch change.kind {
        case .added:
            return InterfaceLocalization.text("新增：\(truncate(change.after?.text ?? ""))")
        case .removed:
            return InterfaceLocalization.text("删除：\(truncate(change.before?.text ?? ""))")
        case .modified:
            let what = change.fields.map(\.rawValue).sorted().joined(separator: "、")
            return InterfaceLocalization.text("第 \(change.index + 1) 句改动了 \(what)")
        }
    }

    static func truncate(_ s: String, limit: Int = 24) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }
}

// MARK: - 撤销栈

/// 通用撤销/重做栈。
public final class UndoStack<State> {
    private var undoStates: [State] = []
    private var redoStates: [State] = []
    private let capacity: Int

    public init(capacity: Int = 50) {
        self.capacity = max(1, capacity)
    }

    public var canUndo: Bool { !undoStates.isEmpty }
    public var canRedo: Bool { !redoStates.isEmpty }
    public var undoCount: Int { undoStates.count }
    public var redoCount: Int { redoStates.count }

    /// 在改动**之前**压入当前状态
    public func record(_ state: State) {
        undoStates.append(state)
        if undoStates.count > capacity {
            undoStates.removeFirst(undoStates.count - capacity)
        }
        redoStates.removeAll()
    }

    public func undo(current: State) -> State? {
        guard let previous = undoStates.popLast() else { return nil }
        redoStates.append(current)
        return previous
    }

    public func redo(current: State) -> State? {
        guard let next = redoStates.popLast() else { return nil }
        undoStates.append(current)
        return next
    }

    public func clear() {
        undoStates.removeAll()
        redoStates.removeAll()
    }
}

// MARK: - 编辑会话

/// 一次字幕编辑会话：持有当前文本、撤销栈、脏标记。
///
/// 界面层只跟这个对象打交道；它自己不碰数据库，保存由上层负责。
public final class SubtitleEditingSession {

    public private(set) var cues: [SubtitleCue]
    public private(set) var isDirty = false
    public private(set) var baseline: [SubtitleCue]

    private let undoStack: UndoStack<[SubtitleCue]>

    public init(cues: [SubtitleCue], undoCapacity: Int = 50) {
        self.cues = cues
        self.baseline = cues
        self.undoStack = UndoStack(capacity: undoCapacity)
    }

    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }

    /// 应用一次改动（会先记录撤销点）
    public func apply(_ transform: ([SubtitleCue]) -> [SubtitleCue]) {
        let next = transform(cues)
        guard next != cues else { return }
        undoStack.record(cues)
        cues = next
        isDirty = true
    }

    /// 不记录撤销点的直接替换（用于撤销/重做本身）
    private func replace(_ next: [SubtitleCue]) {
        cues = next
        isDirty = (next != baseline)
    }

    @discardableResult
    public func undo() -> Bool {
        guard let previous = undoStack.undo(current: cues) else { return false }
        replace(previous)
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard let next = undoStack.redo(current: cues) else { return false }
        replace(next)
        return true
    }

    /// 与 AI 原版的差异
    public func diffFromBaseline() -> [CueChange] {
        CueDiffer.diff(baseline, cues)
    }

    /// 统计"改了多少处"，用于版本备注的自动生成
    public func changeCountFromBaseline() -> Int {
        diffFromBaseline().count
    }

    /// 自动生成版本备注
    public func suggestedVersionNote() -> String {
        let n = changeCountFromBaseline()
        return n == 0 ? InterfaceLocalization.text("无改动") : InterfaceLocalization.text("手工修正 \(n) 处")
    }

    /// 保存后调用：把当前状态设为新基线
    public func commitAsBaseline() {
        baseline = cues
        isDirty = false
        undoStack.clear()
    }
}

// MARK: - 版本仓库

/// 管理一套字幕的所有版本。
public final class SubtitleVersionStore {

    public private(set) var versions: [SubtitleVersion]
    public private(set) var activeID: UUID

    public init(initialCues: [SubtitleCue], note: String = "AI 识别") {
        let baseline = SubtitleVersion(
            number: 1,
            note: note,
            isBaseline: true,
            cues: initialCues
        )
        self.versions = [baseline]
        self.activeID = baseline.id
    }

    public var activeVersion: SubtitleVersion {
        versions.first { $0.id == activeID } ?? versions[0]
    }

    public var baselineVersion: SubtitleVersion? {
        versions.first { $0.isBaseline }
    }

    /// 用当前编辑结果新建一个版本并切换过去
    @discardableResult
    public func createVersion(from cues: [SubtitleCue], note: String) -> SubtitleVersion {
        let nextNumber = (versions.map(\.number).max() ?? 0) + 1
        let version = SubtitleVersion(
            number: nextNumber,
            note: note,
            cues: cues,
            basedOn: activeID
        )
        versions.append(version)
        activeID = version.id
        return version
    }

    @discardableResult
    public func switchTo(_ id: UUID) -> Bool {
        guard versions.contains(where: { $0.id == id }) else { return false }
        activeID = id
        return true
    }

    /// 只保留"基线 + 最近 keep 个非基线版本"
    public func prune(keepingLast keep: Int) {
        let baselines = versions.filter(\.isBaseline)
        var others = versions.filter { !$0.isBaseline }
        guard others.count > keep else { return }
        others.sort { $0.number > $1.number }
        let kept = Array(others.prefix(keep))
        let removedIDs = Set(others.dropFirst(keep).map(\.id))
        versions = (baselines + kept).sorted { $0.number < $1.number }
        if removedIDs.contains(activeID) {
            activeID = versions.last?.id ?? versions[0].id
        }
    }

    @discardableResult
    public func delete(_ id: UUID) -> Bool {
        guard let target = versions.first(where: { $0.id == id }), !target.isBaseline else { return false }
        versions.removeAll { $0.id == id }
        if activeID == id {
            activeID = versions.last?.id ?? versions[0].id
        }
        return true
    }

    public func comparison(from oldID: UUID, to newID: UUID) -> [CueChange] {
        guard let a = versions.first(where: { $0.id == oldID }),
              let b = versions.first(where: { $0.id == newID })
        else { return [] }
        return CueDiffer.diff(a.cues, b.cues)
    }
}
