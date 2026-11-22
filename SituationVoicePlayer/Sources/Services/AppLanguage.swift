import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant"
    case japanese = "ja", english = "en", korean = "ko"
    var id: String { rawValue }
    var name: String {
        switch self {
        case .system: L10n.text("跟随系统")
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .english: "English"
        case .korean: "한국어"
        }
    }
}

@Observable
final class AppLanguageSelection {
    static let shared = AppLanguageSelection()
    var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: InterfaceLocalization.preferenceKey) }
    }
    private(set) var systemLanguages = Locale.preferredLanguages
    var code: String { InterfaceLocalization.language(preference: language.rawValue, preferredLanguages: systemLanguages) }
    var locale: Locale { Locale(identifier: code) }

    private init() {
        language = UserDefaults.standard.string(forKey: InterfaceLocalization.preferenceKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func refreshSystemLanguage() {
        let updated = Locale.preferredLanguages
        if updated != systemLanguages { systemLanguages = updated }
    }
}

/// Reading the observable choice here also refreshes computed labels in SwiftUI
/// without rebuilding the player/store or discarding the navigation stack.
enum L10n {
    static func text(_ message: InterfaceMessage) -> String {
        InterfaceLocalization.text(message, language: AppLanguageSelection.shared.code)
    }
    static func key(_ key: String) -> String {
        InterfaceLocalization.key(key, language: AppLanguageSelection.shared.code)
    }
}

extension WorkCategory {
    /// Translate unchanged built-in labels at display time. A renamed group is
    /// user data; neither its stored title nor its editor field is translated.
    var localizedTitle: String {
        let original = key == "attachments" ? "作品附件" : TrackCategory(rawValue: key)?.displayName
        return isBuiltin && title == original ? L10n.key(title) : title
    }
}

extension ScriptSection {
    /// The core displayName also participates in legacy source identity, so only
    /// the view uses a localized caption; importing continues to use its stable label.
    var localizedDisplayName: String {
        if let trackNumber {
            return title.isEmpty ? L10n.text("第 \(trackNumber) 轨") : L10n.text("第 \(trackNumber) 轨 · \(title)")
        }
        return title.isEmpty ? L10n.text("整份台本") : title
    }
}
