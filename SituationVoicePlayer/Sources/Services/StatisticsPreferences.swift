import SwiftUI
import Combine

/// 统计视图里可单独开关展示的模块。
enum StatisticsModule: String, CaseIterable, Identifiable, Sendable {
    case summary, trend, hours, rankings
    var id: String { rawValue }

    static let defaultOrder: [StatisticsModule] = [.summary, .trend, .hours, .rankings]

    var displayName: String {
        switch self {
        case .summary: return InterfaceLocalization.text("概览")
        case .trend: return InterfaceLocalization.text("收听趋势")
        case .hours: return InterfaceLocalization.text("24 小时时段")
        case .rankings: return InterfaceLocalization.text("收听排行")
        }
    }

    var iconName: String {
        switch self {
        case .summary: return "square.grid.2x2"
        case .trend: return "chart.bar"
        case .hours: return "clock"
        case .rankings: return "list.number"
        }
    }
}

/// 两个库都启用时，统计按合并还是分开展示。
enum StatisticsDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case combined, separate
    var id: String { rawValue }
    var displayName: String { self == .combined ? InterfaceLocalization.text("合并统计") : InterfaceLocalization.text("分开展示") }
}

/// 统计页当前查看的库范围（合并 / 个人 / 合集）。
enum StatisticsScope: String, CaseIterable, Identifiable, Sendable {
    case combined, personal, collection
    var id: String { rawValue }

    var libraryKind: MediaLibraryKind? {
        switch self {
        case .combined: return nil
        case .personal: return .personal
        case .collection: return .collection
        }
    }

    var displayName: String {
        switch self {
        case .combined: return InterfaceLocalization.text("全部统计")
        case .personal: return MediaLibraryKind.personal.displayName
        case .collection: return MediaLibraryKind.collection.displayName
        }
    }

    /// 页面/报告/分享图上的范围标签。
    var scopeLabel: String {
        switch self {
        case .combined: return InterfaceLocalization.text("统计范围：合并（个人音声 + 社团作品）")
        case .personal: return InterfaceLocalization.text("统计范围：仅个人音声")
        case .collection: return InterfaceLocalization.text("统计范围：仅社团作品")
        }
    }

    func contains(_ kind: MediaLibraryKind?) -> Bool {
        guard let wanted = libraryKind else { return true }
        // libraryKind 为 nil 的独立片段不属于任何库，只出现在合并范围里。
        return kind == wanted
    }

    func filter(_ rows: [PlayStatRow]) -> [PlayStatRow] {
        guard libraryKind != nil else { return rows }
        return rows.filter { contains($0.libraryKind) }
    }
}

enum StatisticsDefaultsKey {
    static let personalEnabled = "stats.library.personalEnabled"
    static let collectionEnabled = "stats.library.collectionEnabled"
    static let displayMode = "stats.library.displayMode"
    static let moduleOrder = "stats.widgets.order"
    static let trendEnabled = "stats.widgets.trend"
    static let hoursEnabled = "stats.widgets.hours"
    static let monthlyReviewEnabled = "stats.review.monthly"
    static let annualReviewEnabled = "stats.review.annual"
    static let exportScopeLabel = "stats.export.scopeLabel"

    static var all: [String] {
        [personalEnabled, collectionEnabled, displayMode, moduleOrder,
         trendEnabled, hoursEnabled, monthlyReviewEnabled, annualReviewEnabled, exportScopeLabel]
    }
}

/// 统计显示偏好。只写专用 UserDefaults 键，不改 LibraryStore 或数据库。
final class StatisticsPreferences: ObservableObject {
    static let shared = StatisticsPreferences()
    /// 主题变更广播：用户在设置页修改后，统计页据此刷新界面。
    static let didChangeNotification = Notification.Name("StatisticsPreferences.didChange")

    private let defaults: UserDefaults
    @Published private(set) var personalEnabled: Bool
    @Published private(set) var collectionEnabled: Bool
    @Published private(set) var displayMode: StatisticsDisplayMode
    @Published private(set) var moduleOrder: [StatisticsModule]
    @Published private(set) var trendEnabled: Bool
    @Published private(set) var hoursEnabled: Bool
    @Published private(set) var monthlyReviewEnabled: Bool
    @Published private(set) var annualReviewEnabled: Bool
    private var cancellables: Set<AnyCancellable> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: StatisticsDefaultsKey.moduleOrder) ?? []
        moduleOrder = Self.normalizeOrder(stored.compactMap(StatisticsModule.init(rawValue:)))
        personalEnabled = defaults.object(forKey: StatisticsDefaultsKey.personalEnabled) as? Bool ?? true
        collectionEnabled = defaults.object(forKey: StatisticsDefaultsKey.collectionEnabled) as? Bool ?? true
        displayMode = StatisticsDisplayMode(rawValue: defaults.string(forKey: StatisticsDefaultsKey.displayMode) ?? "")
            ?? .combined
        trendEnabled = defaults.object(forKey: StatisticsDefaultsKey.trendEnabled) as? Bool ?? true
        hoursEnabled = defaults.object(forKey: StatisticsDefaultsKey.hoursEnabled) as? Bool ?? true
        monthlyReviewEnabled = defaults.object(forKey: StatisticsDefaultsKey.monthlyReviewEnabled) as? Bool ?? true
        annualReviewEnabled = defaults.object(forKey: StatisticsDefaultsKey.annualReviewEnabled) as? Bool ?? true
        objectWillChange
            .receive(on: RunLoop.main)
            .sink { _ in NotificationCenter.default.post(name: Self.didChangeNotification, object: nil) }
            .store(in: &cancellables)
    }

    /// 去重、丢弃未知 ID、补齐缺失模块，保持已存顺序。空输入返回默认顺序。
    static func normalizeOrder(_ raw: [StatisticsModule]) -> [StatisticsModule] {
        var seen = Set<StatisticsModule>()
        var result: [StatisticsModule] = []
        for module in raw where !seen.contains(module) {
            seen.insert(module)
            result.append(module)
        }
        for module in StatisticsModule.defaultOrder where !seen.contains(module) {
            result.append(module)
        }
        return result
    }

    // MARK: 按库启用

    func setEnabled(_ enabled: Bool, for kind: MediaLibraryKind) {
        switch kind {
        case .personal: personalEnabled = enabled
        case .collection: collectionEnabled = enabled
        }
        persistLibrarySettings()
    }

    func isEnabled(_ kind: MediaLibraryKind) -> Bool {
        kind == .personal ? personalEnabled : collectionEnabled
    }

    /// 目前启用的库；至少一个。
    var enabledKinds: [MediaLibraryKind] {
        var kinds: [MediaLibraryKind] = []
        if personalEnabled { kinds.append(.personal) }
        if collectionEnabled { kinds.append(.collection) }
        return kinds
    }

    var bothEnabled: Bool { personalEnabled && collectionEnabled }

    func setDisplayMode(_ mode: StatisticsDisplayMode) {
        displayMode = mode
        defaults.set(mode.rawValue, forKey: StatisticsDefaultsKey.displayMode)
    }

    /// 根据启用情况与展示方式得到可用的查看范围。
    var availableScopes: [StatisticsScope] {
        if bothEnabled {
            return displayMode == .combined ? [.combined, .personal, .collection] : [.personal, .collection]
        }
        return enabledKinds.map { $0 == .personal ? .personal : .collection }
    }

    func defaultScope() -> StatisticsScope {
        availableScopes.first ?? .combined
    }

    func normalize(_ scope: StatisticsScope) -> StatisticsScope {
        let scopes = availableScopes
        return scopes.contains(scope) ? scope : (scopes.first ?? .combined)
    }

    // MARK: 组件开关与顺序

    func isEnabled(_ module: StatisticsModule) -> Bool {
        switch module {
        case .summary: return true
        case .trend: return trendEnabled
        case .hours: return hoursEnabled
        case .rankings: return true
        }
    }

    func isPinned(_ module: StatisticsModule) -> Bool {
        module == .summary || module == .rankings
    }

    func setEnabled(_ enabled: Bool, for module: StatisticsModule) {
        switch module {
        case .trend: trendEnabled = enabled
        case .hours: hoursEnabled = enabled
        case .summary, .rankings: return
        }
        defaults.set(enabled, forKey: module == .trend ? StatisticsDefaultsKey.trendEnabled : StatisticsDefaultsKey.hoursEnabled)
    }

    func move(from source: IndexSet, to destination: Int) {
        var order = moduleOrder
        order.move(fromOffsets: source, toOffset: destination)
        updateOrder(order)
    }

    func updateOrder(_ order: [StatisticsModule]) {
        let normalized = Self.normalizeOrder(order)
        guard normalized != moduleOrder else { return }
        moduleOrder = normalized
        defaults.set(normalized.map(\.rawValue), forKey: StatisticsDefaultsKey.moduleOrder)
    }

    func resetModules() {
        updateOrder(StatisticsModule.defaultOrder)
        setEnabled(true, for: .trend)
        setEnabled(true, for: .hours)
    }

    /// 统计页实际展示的模块：按保存的顺序，过滤掉关闭的模块。
    var visibleModules: [StatisticsModule] {
        moduleOrder.filter { isEnabled($0) }
    }

    // MARK: 回顾

    func setMonthlyReviewEnabled(_ enabled: Bool) {
        monthlyReviewEnabled = enabled
        defaults.set(enabled, forKey: StatisticsDefaultsKey.monthlyReviewEnabled)
    }

    func setAnnualReviewEnabled(_ enabled: Bool) {
        annualReviewEnabled = enabled
        defaults.set(enabled, forKey: StatisticsDefaultsKey.annualReviewEnabled)
    }

    func isReviewEnabled(_ kind: ListeningReviewKind) -> Bool {
        kind == .monthly ? monthlyReviewEnabled : annualReviewEnabled
    }

    var reviewKinds: [ListeningReviewKind] {
        ListeningReviewKind.allCases.filter { isReviewEnabled($0) }
    }

    /// 分享图是否标注统计范围（默认标注，避免分享出去的总数与页面范围不一致）。
    var exportScopeLabels: Bool {
        get { defaults.object(forKey: StatisticsDefaultsKey.exportScopeLabel) as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: StatisticsDefaultsKey.exportScopeLabel) }
    }

    // MARK: 重置

    func resetAll() {
        let order = StatisticsModule.defaultOrder
        personalEnabled = true
        collectionEnabled = true
        displayMode = .combined
        trendEnabled = true
        hoursEnabled = true
        monthlyReviewEnabled = true
        annualReviewEnabled = true
        defaults.set(personalEnabled, forKey: StatisticsDefaultsKey.personalEnabled)
        defaults.set(collectionEnabled, forKey: StatisticsDefaultsKey.collectionEnabled)
        defaults.set(displayMode.rawValue, forKey: StatisticsDefaultsKey.displayMode)
        defaults.set(order.map(\.rawValue), forKey: StatisticsDefaultsKey.moduleOrder)
        defaults.set(true, forKey: StatisticsDefaultsKey.trendEnabled)
        defaults.set(true, forKey: StatisticsDefaultsKey.hoursEnabled)
        defaults.set(true, forKey: StatisticsDefaultsKey.monthlyReviewEnabled)
        defaults.set(true, forKey: StatisticsDefaultsKey.annualReviewEnabled)
        defaults.set(true, forKey: StatisticsDefaultsKey.exportScopeLabel)
        moduleOrder = order
    }

    private func persistLibrarySettings() {
        defaults.set(personalEnabled, forKey: StatisticsDefaultsKey.personalEnabled)
        defaults.set(collectionEnabled, forKey: StatisticsDefaultsKey.collectionEnabled)
    }
}
