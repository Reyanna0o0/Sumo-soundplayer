import Foundation
import Combine
import ResourceAccessCore
import ResourceAccessHTTP
import ResourceAccessSMB
import ResourceAccessAMSMB2

struct NetworkTrackResource: Codable, Equatable, Sendable {
    let sourceID: UUID
    let path: ResourcePath
    let expectedRevision: ResourceRevision?
    let byteCount: Int64?
}

struct NetworkLibrarySource: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { connection.id }
    var librarySourceID: Int64
    var name: String
    var connection: SourceConnection
    var directHTTPPath: ResourcePath?
    var enabled: Bool
    var requiresSMBEncryption: Bool
    var revision: UUID
    var address: String { directHTTPPath?.url(relativeTo: connection.endpoint).absoluteString ?? connection.endpoint.absoluteString }
}

enum NetworkLibraryKind: String, CaseIterable, Identifiable {
    case smb = "SMB", http = "HTTP / HTTPS", webDAV = "WebDAV"
    var id: String { rawValue }
    var kind: SourceKind { switch self { case .smb: return .smb; case .http: return .http; case .webDAV: return .webDAV } }
    var sourceType: SourceType { switch self { case .smb: return .smb; case .http: return .http; case .webDAV: return .webdav } }
    var placeholder: String {
        switch self {
        case .smb: return InterfaceLocalization.text("smb://服务器/共享名/目录")
        case .http: return InterfaceLocalization.text("https://服务器/音频.mp3")
        case .webDAV: return InterfaceLocalization.text("https://服务器/选定目录/")
        }
    }
    init(_ kind: SourceKind) { self = kind == .smb ? .smb : kind == .webDAV ? .webDAV : .http }
}

enum NetworkLibraryError: LocalizedError {
    case unavailable, blankName, duplicateSelection, changedDuringOperation, emptySelection, rebindNeedsConfirmation, backupInProgress, unreadableRegistry
    var errorDescription: String? {
        switch self {
        case .unavailable: return InterfaceLocalization.text("网络来源已停用或暂不可用，请在设置中检查连接。")
        case .blankName: return InterfaceLocalization.text("请输入名称。")
        case .duplicateSelection: return InterfaceLocalization.text("所选文件中有已经导入的音轨，请保留原作品，或取消选择这些文件。")
        case .changedDuringOperation: return InterfaceLocalization.text("操作期间来源已改变，请重新连接后再试。")
        case .emptySelection: return InterfaceLocalization.text("请选择 1 至 500 个 MP3、M4A 或 WAV 音频文件。")
        case .rebindNeedsConfirmation: return InterfaceLocalization.text("请先确认新位置包含同一批原文件，再重新绑定。")
        case .backupInProgress: return InterfaceLocalization.text("正在备份或准备恢复，请完成后再修改网络来源或导入作品。")
        case .unreadableRegistry: return InterfaceLocalization.text("网络来源配置无法读取。为保护现有资料，暂不覆盖配置；本地媒体库仍可使用。")
        }
    }
}

/// Sources are connection records, not a third library. Only explicit selection
/// imports catalogue rows; reconnecting or listing never imports or deletes works.
@MainActor
final class NetworkLibraryService: ObservableObject {
    static let shared = NetworkLibraryService()
    @Published private(set) var sources: [NetworkLibrarySource] = []
    @Published private(set) var configurationIssues: [String] = []
    private var repository: LibraryRepository?
    private var unreadableSourceRecords: [Any] = []
    private var registryIsUnreadable = false
    private let credentials = NetworkLibraryCredentials()
    private let sourcesKey = "networkLibrary.sources.v1"
    static let supportedAudio: Set<String> = ["mp3", "m4a", "wav"]

    func attach(repository: LibraryRepository) throws {
        self.repository = repository
        var restored: [NetworkLibrarySource] = [], issues: [String] = [], unreadable: [Any] = []
        registryIsUnreadable = false
        do {
            if let json = try repository.setting(sourcesKey) {
                guard let records = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else {
                    throw NetworkLibraryError.unreadableRegistry
                }
                var seen = Set<UUID>()
                for record in records {
                    do {
                        guard record is [String: Any] else { throw NetworkLibraryError.unreadableRegistry }
                        let data = try JSONSerialization.data(withJSONObject: record)
                        let source = try JSONDecoder().decode(NetworkLibrarySource.self, from: data)
                        guard [.smb, .http, .webDAV].contains(source.connection.kind),
                              source.librarySourceID > 0, seen.insert(source.id).inserted else {
                            throw NetworkLibraryError.unreadableRegistry
                        }
                        restored.append(source)
                    } catch {
                        unreadable.append(record)
                        issues.append((record as? [String: Any])?["name"] as? String ?? InterfaceLocalization.text("未命名来源"))
                    }
                }
            }
        } catch {
            registryIsUnreadable = true
            issues = [InterfaceLocalization.text("网络来源配置")]
        }
        sources = restored; configurationIssues = issues; unreadableSourceRecords = unreadable
    }

    func resource(for trackID: Int64) throws -> NetworkTrackResource? {
        guard let repository else { throw NetworkLibraryError.unavailable }
        guard try repository.track(id: trackID) != nil,
              let json = try repository.setting("networkTrack.\(trackID)") else { return nil }
        return try JSONDecoder().decode(NetworkTrackResource.self, from: Data(json.utf8))
    }

    func adapter(for sourceID: UUID) async throws -> any ResourceAdapter {
        guard let source = sources.first(where: { $0.id == sourceID && $0.enabled }) else {
            throw NetworkLibraryError.unavailable
        }
        return try makeAdapter(source, credentials: credentials)
    }

    func storedCredential(for source: NetworkLibrarySource) throws -> ResourceCredential? {
        try source.connection.credentialReference.flatMap { try credentials.read($0) }
    }

    /// Rebinding keeps the database source/work/track IDs and checks only already
    /// imported locators, never the entire remote directory tree.
    func save(existing: NetworkLibrarySource?, name: String, kind: NetworkLibraryKind,
              address: String, username: String, password: String, domain: String,
              allowsHTTP: Bool, requiresEncryption: Bool, confirmRebind: Bool = false) async throws {
        try requireWritable()
        guard let repository else { throw NetworkLibraryError.unavailable }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NetworkLibraryError.blankName }
        let id = existing?.id ?? UUID()
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty || password.isEmpty else { throw ResourceAccessError.authorizationRequired }
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ResourceAccessError.invalidConfiguration("Address")
        }
        let root: URL
        let directPath: ResourcePath?
        if kind == .http {
            guard !url.hasDirectoryPath, !url.lastPathComponent.isEmpty, url.path != "/",
                  Self.supportedAudio.contains(url.pathExtension.lowercased()) else {
                throw ResourceAccessError.invalidConfiguration("Expected direct audio URL")
            }
            directPath = try ResourcePath("").appending(url.lastPathComponent)
            root = url.deletingLastPathComponent()
        } else { root = url; directPath = nil }
        let reference = user.isEmpty ? nil : CredentialReference("network-source-" + id.uuidString)
        let credential: ResourceCredential? = user.isEmpty ? nil : .usernamePassword(username: user, password: password,
            domain: kind == .smb && !domain.isEmpty ? domain : nil)
        let connection = try SourceConnection(id: id, kind: kind.kind, endpoint: root,
            credentialReference: reference, allowsInsecureHTTP: allowsHTTP)
        let source = NetworkLibrarySource(librarySourceID: existing?.librarySourceID ?? 0, name: name,
            connection: connection, directHTTPPath: directPath, enabled: true,
            requiresSMBEncryption: kind == .smb && requiresEncryption, revision: UUID())
        let locationChanged = existing.map { $0.connection.endpoint != root || $0.connection.kind != connection.kind
            || $0.directHTTPPath != directPath } ?? false
        if locationChanged && !confirmRebind { throw NetworkLibraryError.rebindNeedsConfirmation }
        let temporary = InMemoryCredentialStore()
        if let reference { await temporary.set(credential, for: reference) }
        let adapter = try makeAdapter(source, credentials: temporary)
        if let directPath { _ = try await adapter.metadata(at: directPath) }
        else { _ = try await adapter.listChildren(at: .root) }
        var updatedResources: [Int64: NetworkTrackResource] = [:]
        if locationChanged, let existing {
            let oldTracks = try repository.works(sourceID: existing.librarySourceID).flatMap { try repository.tracks(workID: $0.id) }
            if kind == .http && oldTracks.count > 1 {
                throw ResourceAccessError.invalidConfiguration("Multiple tracks cannot bind to a single HTTP file")
            }
            for work in try repository.works(sourceID: existing.librarySourceID) {
                for track in try repository.tracks(workID: work.id) {
                    guard let old = try resource(for: track.id), old.sourceID == id else { continue }
                    // An HTTP source owns a single explicitly supplied file.
                    let path = kind == .http ? (directPath ?? old.path) : old.path
                    let metadata = try await adapter.metadata(at: path)
                    guard !metadata.isDirectory,
                          old.expectedRevision?.contentMatchAcrossLocations(metadata.revision) != .different else {
                        throw ResourceAccessError.resourceChanged
                    }
                    updatedResources[track.id] = NetworkTrackResource(sourceID: id, path: path,
                        expectedRevision: metadata.revision, byteCount: metadata.size)
                }
            }
        }
        try Task.checkCancellation()
        try requireWritable()
        if let existing, sources.first(where: { $0.id == id }) != existing {
            throw NetworkLibraryError.changedDuringOperation
        }
        let oldReference = existing?.connection.credentialReference
        let oldCredential = try oldReference.flatMap { try credentials.read($0) }
        if let reference { try credentials.set(credential, for: reference) }
        do {
            var all = sources
            var saved = source
            try repository.networkTransaction {
                saved.librarySourceID = try repository.saveSource(LibrarySource(id: source.librarySourceID,
                    name: name, type: kind.sourceType, rootPath: nil, enabled: true))
                all.removeAll { $0.id == id }; all.append(saved)
                try repository.setSetting(sourcesKey, encodedSources(all))
                for (trackID, resource) in updatedResources {
                    try repository.setSetting("networkTrack.\(trackID)", Self.json(resource))
                }
            }
            sources = all
            if let oldReference, oldReference != reference { try? credentials.set(nil, for: oldReference) }
        } catch {
            if let reference { try? credentials.set(oldCredential, for: reference) }
            throw error
        }
    }

    func deactivate(_ source: NetworkLibrarySource) throws {
        try requireWritable()
        guard let repository, let index = sources.firstIndex(where: { $0.id == source.id }) else {
            throw NetworkLibraryError.unavailable
        }
        var all = sources
        all[index].enabled = false; all[index].revision = UUID()
        try repository.networkTransaction {
            _ = try repository.saveSource(LibrarySource(id: source.librarySourceID, name: source.name,
                type: NetworkLibraryKind(source.connection.kind).sourceType, rootPath: nil, enabled: false))
            try repository.setSetting(sourcesKey, encodedSources(all))
        }
        sources = all
        if let reference = source.connection.credentialReference { try credentials.set(nil, for: reference) }
    }

    func importSelection(source: NetworkLibrarySource, paths: [ResourcePath], title: String,
                         library: MediaLibraryKind, creatorID: Int64?, coverAssetPath: String?) async throws -> Int64 {
        try requireWritable()
        guard let repository, sources.contains(source), source.enabled else { throw NetworkLibraryError.unavailable }
        guard !paths.isEmpty, paths.count <= 500, Set(paths).count == paths.count,
              paths.allSatisfy({ Self.supportedAudio.contains(($0.string as NSString).pathExtension.lowercased()) }) else {
            throw NetworkLibraryError.emptySelection
        }
        try rejectDuplicatePaths(paths, source: source, repository: repository)
        let adapter = try await adapter(for: source.id)
        var candidates: [NetworkImportTrack] = []
        for path in paths {
            let metadata = try await adapter.metadata(at: path)
            guard !metadata.isDirectory else { throw NetworkLibraryError.emptySelection }
            let resource = NetworkTrackResource(sourceID: source.id, path: path,
                expectedRevision: metadata.revision, byteCount: metadata.size)
            candidates.append(NetworkImportTrack(name: path.components.last ?? "", relativePath: path.string,
                fileType: (path.string as NSString).pathExtension.lowercased(), byteCount: metadata.size,
                modifiedAt: metadata.revision.modifiedAt, resourceJSON: try Self.json(resource)))
        }
        try Task.checkCancellation()
        try requireWritable()
        guard sources.contains(source) else { throw NetworkLibraryError.changedDuringOperation }
        // A second import may have committed while this import awaited metadata.
        try rejectDuplicatePaths(paths, source: source, repository: repository)
        return try repository.importNetworkWork(sourceID: source.librarySourceID, title: title, library: library,
            creatorID: library == .personal ? creatorID : nil, coverAssetPath: coverAssetPath, tracks: candidates)
    }

    static func message(for error: Error) -> String {
        if let own = error as? NetworkLibraryError { return own.localizedDescription }
        guard let error = error as? ResourceAccessError else {
            if error is CancellationError { return InterfaceLocalization.text("操作已取消。") }
            return InterfaceLocalization.text("暂时无法完成操作，请检查网络与来源设置后重试。")
        }
        let message: String
        switch error {
        case .authorizationRequired: message = "连接需要授权，请检查用户名和密码。"
        case .permissionDenied: message = "此账号没有读取所选目录或文件的权限。"
        case .notFound: message = "找不到所选目录或文件，请检查地址或重新绑定来源。"
        case .temporarilyUnavailable: message = "来源暂时离线，请确认设备和网络连接后重试。"
        case .timedOut: message = "连接超时，请检查网络后重试。"
        case .cancelled: message = "操作已取消。"
        case .resourceChanged: message = "新位置的文件与原记录不一致，未重新绑定，请确认选择的是原文件。"
        case .invalidConfiguration, .invalidPath: message = "地址格式不正确。请填写无账号、查询参数的目录地址；HTTP 请填写 MP3、M4A 或 WAV 文件地址。"
        case .unsupported: message = "服务器暂不支持所需读取方式，请检查协议、文件格式或服务器设置。"
        case .invalidResponse: message = "服务器返回的文件资料不符合预期，请稍后重试。"
        case .limitExceeded: message = "所选目录或文件超出本次读取上限，请选择更小的目录。"
        }
        return InterfaceLocalization.key(message)
    }

    private func makeAdapter(_ source: NetworkLibrarySource, credentials: any CredentialProvider) throws -> any ResourceAdapter {
        if source.connection.kind == .smb {
            return try SMBResourceAdapter(connection: source.connection, credentialProvider: credentials,
                transport: AMSMB2Transport(operationTimeout: 25), requiresEncryption: source.requiresSMBEncryption)
        }
        return try HTTPResourceAdapter(connection: source.connection, credentials: credentials, timeout: 25)
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func encodedSources(_ sources: [NetworkLibrarySource]) throws -> String {
        guard let valid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sources)) as? [Any] else {
            throw NetworkLibraryError.unreadableRegistry
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: valid + unreadableSourceRecords), as: UTF8.self)
    }

    private func rejectDuplicatePaths(_ paths: [ResourcePath], source: NetworkLibrarySource,
                                      repository: LibraryRepository) throws {
        let selected = Set(paths)
        for work in try repository.works(sourceID: source.librarySourceID) {
            for track in try repository.tracks(workID: work.id) {
                if let locator = try resource(for: track.id), selected.contains(locator.path) {
                    throw NetworkLibraryError.duplicateSelection
                }
            }
        }
    }

    private func requireWritable() throws {
        guard !registryIsUnreadable else { throw NetworkLibraryError.unreadableRegistry }
        guard !LibraryBackupCoordinator.shared.playbackLocked,
              !LibraryBackupCoordinator.shared.isBusy && !LibraryBackupCoordinator.shared.restoreReady else {
            throw NetworkLibraryError.backupInProgress
        }
    }
}
