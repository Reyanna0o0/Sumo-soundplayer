import Foundation
import ResourceAccessCore

struct HTTPPathScope: Sendable {
    let root: URL
    private let rootComponents: [String]

    init(root: URL) throws {
        guard root.user == nil, root.password == nil, root.query == nil, root.fragment == nil,
              ["http", "https"].contains(root.scheme?.lowercased() ?? ""), root.host != nil else {
            throw ResourceAccessError.invalidConfiguration("Invalid HTTP selected root")
        }
        self.root = root
        rootComponents = try Self.pathComponents(root)
    }

    func url(for path: ResourcePath, directory: Bool = false) throws -> URL {
        var url = root
        for component in path.components {
            try Self.validateComponent(component)
            url.appendPathComponent(component, isDirectory: false)
        }
        if directory, !url.absoluteString.hasSuffix("/") {
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            parts.percentEncodedPath += "/"
            guard let value = parts.url else { throw ResourceAccessError.invalidPath("Invalid directory URL") }
            url = value
        }
        guard contains(url) else { throw ResourceAccessError.invalidPath("Path leaves selected root") }
        return url
    }

    func contains(_ url: URL) -> Bool {
        guard Self.sameOrigin(root, url), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let parts = try? Self.pathComponents(url), parts.starts(with: rootComponents) else { return false }
        return true
    }

    func childPath(href: String, requestedDirectory: URL, directoryPath: ResourcePath) throws -> ResourcePath? {
        let clean = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("\\"), !clean.unicodeScalars.contains(where: { $0.value < 0x20 }),
              let candidate = URL(string: clean, relativeTo: requestedDirectory)?.absoluteURL,
              contains(candidate) else { throw ResourceAccessError.invalidResponse("WebDAV href outside selected root") }
        // Reject dot segments in the original href too: URL resolution can erase them.
        let original = URLComponents(string: clean)?.percentEncodedPath ?? clean
        _ = try Self.decodeComponents(original)
        let parent = try Self.pathComponents(requestedDirectory)
        let child = try Self.pathComponents(candidate)
        if child == parent { return nil } // PROPFIND also returns the requested collection itself.
        guard child.starts(with: parent), child.count == parent.count + 1, let name = child.last else {
            throw ResourceAccessError.invalidResponse("Depth:1 response contains a non-child resource")
        }
        return try directoryPath.appending(name)
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ u: URL) -> Int { u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }

    private static func pathComponents(_ url: URL) throws -> [String] {
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else {
            throw ResourceAccessError.invalidPath("Invalid encoded path")
        }
        return try decodeComponents(path)
    }

    private static func decodeComponents(_ path: String) throws -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        var result: [String] = []
        for (index, part) in components.enumerated() {
            if part.isEmpty {
                guard index == 0 || index == components.count - 1 else {
                    throw ResourceAccessError.invalidPath("Empty interior URL path component")
                }
                continue
            }
            guard let decoded = String(part).removingPercentEncoding else {
                throw ResourceAccessError.invalidPath("Invalid percent encoding")
            }
            try validateComponent(decoded)
            result.append(decoded)
        }
        return result
    }

    private static func validateComponent(_ component: String) throws {
        guard !component.isEmpty, component != ".", component != "..", !component.contains("/"),
              !component.contains("\\"), !component.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            throw ResourceAccessError.invalidPath("Invalid URL path component")
        }
        // A second decoding pass must not turn a literal percent name into a
        // separator or traversal component on a differently configured server.
        if let decodedAgain = component.removingPercentEncoding, decodedAgain != component {
            guard decodedAgain != ".", decodedAgain != "..", !decodedAgain.contains("/"),
                  !decodedAgain.contains("\\"), !decodedAgain.contains("\0") else {
                throw ResourceAccessError.invalidPath("Ambiguous double-encoded path")
            }
        }
    }
}
