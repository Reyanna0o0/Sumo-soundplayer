import Foundation

public enum DirectLinkSite: String, Codable, Sendable { case soundgasm, scriptbin }
public enum DirectLinkError: LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public struct DirectLink: Equatable, Sendable {
    public let site: DirectLinkSite
    public let url: URL
    public let uploadAccount: String

    public init(_ input: String, site: DirectLinkSite) throws {
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil,
              [site == .soundgasm ? "soundgasm.net" : "scriptbin.works",
               site == .soundgasm ? "www.soundgasm.net" : "www.scriptbin.works"].contains(parts.host?.lowercased() ?? "") else {
            throw DirectLinkError.message(InterfaceLocalization.text("请输入 \(site == .soundgasm ? "Soundgasm" : "Scriptbin") 的作品直链。"))
        }
        let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count == 3, path[0] == "u", !parts.percentEncodedPath.hasSuffix("/"),
              let account = String(path[1]).removingPercentEncoding,
              path.dropFirst().allSatisfy({ piece in
                  guard let decoded = String(piece).removingPercentEncoding else { return false }
                  return !decoded.isEmpty && decoded != "." && decoded != ".." && !decoded.contains("/")
                      && !decoded.contains("\\") && !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              }) else { throw DirectLinkError.message(InterfaceLocalization.text("请粘贴单个作品的完整链接，不能使用主页或账号页。")) }
        parts.scheme = "https"; parts.host = site == .soundgasm ? "soundgasm.net" : "scriptbin.works"
        parts.query = nil; parts.fragment = nil
        guard let url = parts.url else { throw DirectLinkError.message(InterfaceLocalization.text("链接无法识别。")) }
        self.site = site; self.url = url; self.uploadAccount = account
    }

    public static func isSoundgasmAudio(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "media.soundgasm.net"
            && url.user == nil && url.password == nil && url.port == nil
            && url.path.hasPrefix("/sounds/") && url.pathExtension.lowercased() == "m4a"
    }
}

/// Website attribution is evidence, separate from user-managed creator profiles.
public struct DirectLinkMetadata: Codable, Equatable, Sendable {
    public var site: DirectLinkSite
    public var sourceURL: String
    public var title: String
    public var uploadAccount: String
    public var description: String
    public var explicitCredits: String
    public init(link: DirectLink, title: String, description: String = "", explicitCredits: String = "") {
        site = link.site; sourceURL = link.url.absoluteString; uploadAccount = link.uploadAccount
        self.title = title; self.description = description; self.explicitCredits = explicitCredits
    }
}

public struct SoundgasmPage: Equatable, Sendable {
    public let metadata: DirectLinkMetadata
    public let audioURL: URL
    public static func parse(html: String, link: DirectLink) throws -> Self {
        guard link.site == .soundgasm, html.utf8.count <= 2 * 1024 * 1024,
              let titleHTML = capture(#"(?is)<div\b[^>]*\bclass\s*=\s*["'][^"']*\bjp-title\b[^"']*["'][^>]*>(.*?)</div\s*>"#, html),
              let media = capture(#"(?i)\bm4a\s*:\s*["'](https://media\.soundgasm\.net/sounds/[^"'\s]+)["']"#, html),
              let audio = URL(string: media), DirectLink.isSoundgasmAudio(audio) else {
            throw DirectLinkError.message(InterfaceLocalization.text("没有读到 Soundgasm 音频，页面可能已失效或需要登录。尚未导入。"))
        }
        let title = plainText(titleHTML)
        guard !title.isEmpty else { throw DirectLinkError.message(InterfaceLocalization.text("页面没有作品标题，尚未导入。")) }
        let description = capture(#"(?is)<div\b[^>]*\bclass\s*=\s*["'][^"']*\bjp-description\b[^"']*["'][^>]*>(.*?)</div\s*>"#, html).map(plainText) ?? ""
        return Self(metadata: DirectLinkMetadata(link: link, title: title, description: description), audioURL: audio)
    }
    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    /// This path never executes website JavaScript. Decode entities once, after removing markup.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<br\s*/?>|</(?:p|div|li)>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        let entities = ["amp":"&", "lt":"<", "gt":">", "quot":"\"", "apos":"'", "nbsp":" ", "rsquo":"’", "lsquo":"‘", "ldquo":"“", "rdquo":"”", "mdash":"—", "ndash":"–", "hellip":"…", "copy":"©"]
        if let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let full = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { continue }
                let key = String(text[inner]); var replacement = entities[key]
                if key.hasPrefix("#") {
                    let n = key.hasPrefix("#x") ? UInt32(key.dropFirst(2), radix: 16) : UInt32(key.dropFirst())
                    replacement = n.flatMap(UnicodeScalar.init).map(String.init)
                }
                if let replacement { text.replaceSubrange(full, with: replacement) }
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ScriptbinDocument: Equatable, Sendable {
    public let metadata: DirectLinkMetadata
    public let text: String
    public init(link: DirectLink, title: String, text: String, description: String = "") throws {
        let body = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "" : $0 }
            .joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard link.site == .scriptbin, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !body.isEmpty, body.utf8.count <= 2 * 1024 * 1024 else {
            throw DirectLinkError.message(InterfaceLocalization.text("没有读到可保存的台本正文，尚未导入。"))
        }
        metadata = DirectLinkMetadata(link: link, title: title, description: description); self.text = body
    }
    /// Preserve paragraphs and stage directions verbatim. Do not infer timestamps, translations or speakers.
    public var section: ScriptSection {
        ScriptSection(index: 0, lines: text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .enumerated().map { ScriptLine(index: $0.offset, text: $0.element, rawLine: $0.element) })
    }
}
