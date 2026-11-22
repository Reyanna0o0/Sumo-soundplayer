import Foundation

/// Interface text only. User titles, scripts, file paths and database keys never
/// pass through this lookup. The command-line core can run without app resources.
public enum InterfaceLocalization {
    public static let preferenceKey = "appInterfaceLanguage"
    public static let supported = ["en", "zh-Hans", "zh-Hant", "ja", "ko"]

    public static func language(preference: String? = nil, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let choice = preference ?? UserDefaults.standard.string(forKey: preferenceKey) ?? "system"
        if supported.contains(choice) { return choice }
        return Bundle.preferredLocalizations(from: supported, forPreferences: preferredLanguages).first ?? "en"
    }

    public static func text(_ message: InterfaceMessage, language: String? = nil) -> String {
        render(key: message.key, arguments: message.arguments, language: language)
    }

    public static func key(_ key: String, language: String? = nil) -> String {
        render(key: key, arguments: [], language: language)
    }

    private static func render(key: String, arguments: [String], language: String?) -> String {
        let language = language ?? Self.language()
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
        let value = bundle?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
        guard !arguments.isEmpty else { return value }
        // Our interpolation uses numbered tokens rather than printf. Values from
        // files and URLs are inserted verbatim and cannot become format strings.
        var result = ""
        var cursor = value.startIndex
        while let start = value.range(of: "{#", range: cursor..<value.endIndex),
              let end = value[start.upperBound...].firstIndex(of: "}") {
            result += value[cursor..<start.lowerBound]
            if let index = Int(value[start.upperBound..<end]), arguments.indices.contains(index) {
                result += arguments[index]
            } else {
                result += value[start.lowerBound...end]
            }
            cursor = value.index(after: end)
        }
        result += value[cursor...]
        return result
    }
}

/// Numbered interpolation allows translators to reorder values without touching
/// the values themselves. Unlike String(describing:) on a complete sentence,
/// this keeps a stable key for text containing work titles or counts.
public struct InterfaceMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public let key: String
    public let arguments: [String]

    public init(stringLiteral value: String) { key = value; arguments = [] }
    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{#\(arguments.count)}"
            arguments.append(String(describing: value))
        }
    }
}
