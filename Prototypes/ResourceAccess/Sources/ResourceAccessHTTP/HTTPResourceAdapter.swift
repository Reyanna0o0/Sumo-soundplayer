import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ResourceAccessCore

/// Read-only HTTP and WebDAV access within one explicitly selected root.
/// This is a byte/metadata adapter, not a player or an automatic library scanner.
public final class HTTPResourceAdapter: ResourceAdapter, @unchecked Sendable {
    public let connection: SourceConnection
    private let credentials: any CredentialProvider
    private let scope: HTTPPathScope
    private let transport: BoundedHTTPTransport
    private let timeout: TimeInterval
    private let maximumListingBytes: Int
    private let maximumEntries: Int

    public init(connection: SourceConnection, credentials: any CredentialProvider = InMemoryCredentialStore(),
                configuration: URLSessionConfiguration = .ephemeral, timeout: TimeInterval = 20,
                maximumListingBytes: Int = 2_097_152, maximumEntries: Int = 2_000) throws {
        guard connection.kind == .http || connection.kind == .webDAV,
              timeout > 0, timeout.isFinite, maximumListingBytes > 0, maximumEntries > 0, maximumEntries < Int.max else {
            throw ResourceAccessError.invalidConfiguration("Invalid HTTP adapter configuration")
        }
        self.connection = connection; self.credentials = credentials
        scope = try HTTPPathScope(root: connection.endpoint)
        transport = BoundedHTTPTransport(configuration: configuration)
        self.timeout = timeout; self.maximumListingBytes = maximumListingBytes; self.maximumEntries = maximumEntries
    }

    public func metadata(at path: ResourcePath) async throws -> ResourceMetadata {
        let request = try await request(method: "HEAD", path: path)
        let result = try await transport.perform(request, maximumBytes: 0, redirectAllowed: { [scope] in scope.contains($0) }) { response in
            try Self.checkStatus(response, accepted: [200])
            try Self.requireIdentityEncoding(response)
            return .headersOnly
        }
        return try Self.metadata(result.response)
    }

    public func read(at path: ResourcePath, range: ByteRange,
                     expectedRevision: ResourceRevision? = nil) async throws -> ResourceChunk {
        var request = try await request(method: "GET", path: path)
        request.setValue("bytes=\(range.offset)-\(range.lastOffset)", forHTTPHeaderField: "Range")
        if let tag = expectedRevision?.strongETag { request.setValue(tag, forHTTPHeaderField: "If-Range") }
        let result = try await transport.perform(request, maximumBytes: range.length, redirectAllowed: { [scope] in scope.contains($0) }) { response in
            if response.statusCode == 200 {
                // An ignored Range or changed If-Range may yield a whole file.
                // Refuse its body; never append it at the requested offset.
                if let expectedRevision,
                   expectedRevision.match(try Self.metadata(response).revision) == .different {
                    throw ResourceAccessError.resourceChanged
                }
                throw ResourceAccessError.unsupported("Server ignored byte Range; random access is unverified")
            }
            try Self.checkStatus(response, accepted: [206])
            try Self.requireIdentityEncoding(response)
            let contentRange = try ContentRange(response.value(forHTTPHeaderField: "Content-Range"))
            guard contentRange.first == range.offset,
                  contentRange.last == min(range.lastOffset, contentRange.total - 1),
                  contentRange.first <= contentRange.last else {
                throw ResourceAccessError.invalidResponse("Content-Range does not match requested offsets")
            }
            let count = Int(contentRange.last - contentRange.first + 1)
            if let length = response.value(forHTTPHeaderField: "Content-Length") {
                guard Int64(length) == Int64(count) else {
                    throw ResourceAccessError.invalidResponse("Content-Length and Content-Range disagree")
                }
            }
            let actual = try Self.metadata(response, total: contentRange.total).revision
            if let expectedRevision, expectedRevision.match(actual) == .different {
                throw ResourceAccessError.resourceChanged
            }
            return .bytes(expectedLength: count)
        }
        let contentRange = try ContentRange(result.response.value(forHTTPHeaderField: "Content-Range"))
        return ResourceChunk(data: result.data, offset: range.offset, totalLength: contentRange.total,
                             revision: try Self.metadata(result.response, total: contentRange.total).revision)
    }

    public func listChildren(at path: ResourcePath) async throws -> [ResourceEntry] {
        guard connection.kind == .webDAV else { throw ResourceAccessError.unsupported("HTTP does not define directory enumeration") }
        var request = try await request(method: "PROPFIND", path: path, directory: true)
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getcontentlength/><d:getcontenttype/><d:getetag/><d:getlastmodified/></d:prop></d:propfind>".utf8)
        let limit = maximumListingBytes
        let result = try await transport.perform(request, maximumBytes: limit, redirectAllowed: { [scope] in scope.contains($0) }) { response in
            try Self.checkStatus(response, accepted: [207])
            try Self.requireIdentityEncoding(response)
            if let header = response.value(forHTTPHeaderField: "Content-Length") {
                guard let length = Int(header), length >= 0 else { throw ResourceAccessError.invalidResponse("Invalid listing length") }
                guard length <= limit else { throw ResourceAccessError.limitExceeded }
                return .bytes(expectedLength: length)
            }
            return .bytes(expectedLength: nil)
        }
        let records = try DAVMultistatusParser.parse(result.data, maximumEntries: maximumEntries + 1)
        let requested = try scope.url(for: path, directory: true)
        var entries: [ResourceEntry] = [], seen = Set<ResourcePath>()
        for record in records {
            guard let child = try scope.childPath(href: record.href, requestedDirectory: requested, directoryPath: path) else { continue }
            guard seen.insert(child).inserted else { throw ResourceAccessError.invalidResponse("Duplicate WebDAV child identity") }
            guard entries.count < maximumEntries else { throw ResourceAccessError.limitExceeded }
            entries.append(ResourceEntry(path: child, metadata: record.metadata))
        }
        return entries
    }

    public func probe(at path: ResourcePath) async throws -> ResourceProbe {
        let info = try await metadata(at: path)
        var capabilities = ResourceCapabilities()
        if info.size != 0 {
            do {
                _ = try await read(at: path, range: ByteRange(offset: 0, length: 1), expectedRevision: info.revision)
                capabilities.sequentialRead = .supported
                if let size = info.size, size > 1 {
                    _ = try await read(at: path, range: ByteRange(offset: size - 1, length: 1), expectedRevision: info.revision)
                    capabilities.randomAccess = .supported
                }
            } catch ResourceAccessError.unsupported {
                capabilities.randomAccess = .unsupported
            }
        }
        capabilities.verifiedAt = Date()
        // Reading one HTTP range does not prove media seek accuracy, persistent
        // downloads, or an authenticated URL's usability by AVPlayer.
        let access: PlaybackAccess = connection.credentialReference == nil
            ? .httpURL(try scope.url(for: path)) : .byteReader(sourceID: connection.id, path: path)
        return ResourceProbe(metadata: info, residency: .remote,
                             capabilities: capabilities, playbackAccess: access)
    }

    private func request(method: String, path: ResourcePath, directory: Bool = false) async throws -> URLRequest {
        if Task.isCancelled { throw ResourceAccessError.cancelled }
        let url = try scope.url(for: path, directory: directory)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method; request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let reference = connection.credentialReference {
            guard let credential = try await credentials.credential(for: reference) else {
                throw ResourceAccessError.authorizationRequired
            }
            switch credential {
            case .bearer(let token):
                guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else {
                    throw ResourceAccessError.invalidConfiguration("Invalid credential")
                }
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            case .usernamePassword(let username, let password, let domain):
                guard domain == nil || domain == "", !username.contains(":"),
                      !username.contains("\0"), !password.contains("\0") else {
                    throw ResourceAccessError.invalidConfiguration("HTTP Basic credentials do not use an SMB domain")
                }
                let encoded = Data((username + ":" + password).utf8).base64EncodedString()
                request.setValue("Basic " + encoded, forHTTPHeaderField: "Authorization")
            }
        }
        if Task.isCancelled { throw ResourceAccessError.cancelled }
        return request
    }

    private static func checkStatus(_ response: HTTPURLResponse, accepted: Set<Int>) throws {
        if accepted.contains(response.statusCode) { return }
        switch response.statusCode {
        case 401: throw ResourceAccessError.authorizationRequired
        case 403: throw ResourceAccessError.permissionDenied
        case 404, 410: throw ResourceAccessError.notFound
        case 408, 504: throw ResourceAccessError.timedOut
        case 405, 501: throw ResourceAccessError.unsupported("HTTP method is not supported")
        case 429, 500...599: throw ResourceAccessError.temporarilyUnavailable
        case 412: throw ResourceAccessError.resourceChanged
        case 416: throw ResourceAccessError.invalidResponse("Byte range is not satisfiable")
        default: throw ResourceAccessError.invalidResponse("Unexpected HTTP status \(response.statusCode)")
        }
    }

    private static func requireIdentityEncoding(_ response: HTTPURLResponse) throws {
        if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
            throw ResourceAccessError.unsupported("Encoded response cannot be used in raw byte coordinates")
        }
    }

    private static func metadata(_ response: HTTPURLResponse, total: Int64? = nil) throws -> ResourceMetadata {
        var size = total
        if size == nil, let header = response.value(forHTTPHeaderField: "Content-Length") {
            guard let value = Int64(header), value >= 0 else { throw ResourceAccessError.invalidResponse("Invalid Content-Length") }
            size = value
        }
        let modified = response.value(forHTTPHeaderField: "Last-Modified").flatMap(HTTPDate.parse)
        return ResourceMetadata(size: size, mimeType: response.mimeType,
                                revision: ResourceRevision(size: size, etag: response.value(forHTTPHeaderField: "ETag"), modifiedAt: modified))
    }
}

private struct ContentRange {
    let first: Int64
    let last: Int64
    let total: Int64
    init(_ header: String?) throws {
        guard let header, header.hasPrefix("bytes ") else { throw ResourceAccessError.invalidResponse("Missing byte Content-Range") }
        let parts = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Self.decimal(parts[1]), total > 0 else {
            throw ResourceAccessError.invalidResponse("Unknown or invalid complete representation length")
        }
        let offsets = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard offsets.count == 2, let first = Self.decimal(offsets[0]), let last = Self.decimal(offsets[1]),
              first >= 0, last >= first, last < total else { throw ResourceAccessError.invalidResponse("Invalid Content-Range bounds") }
        self.first = first; self.last = last; self.total = total
    }
    private static func decimal(_ text: Substring) -> Int64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(text)
    }
}

enum HTTPDate {
    static func parse(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.isLenient = false
        return formatter.date(from: value)
    }
}
