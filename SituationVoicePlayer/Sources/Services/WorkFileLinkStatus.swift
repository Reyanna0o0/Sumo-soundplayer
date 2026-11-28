import Combine
import Foundation
import UIKit

/// A failed-link hint is derived from current media references, never persisted
/// as a change to the work. Unknown provider/access states are not called missing.
enum WorkFileLinkProbe {
    enum Result: Equatable, Sendable { case available, missing, unknown }
    enum Reference: Sendable {
        case owned(String)
        case source(relative: String, legacyAbsolute: String? = nil)
        case attachment(relative: String)
    }
    struct Snapshot: Sendable {
        let assetsRoot: String
        let appHome: String
        let source: WorkAttachmentSource?
        let references: [Reference]
    }

    // The default performs the real OS authorization request. Tests can supply
    // a denied request without depending on simulator sandbox permissions.
    static func inspect(_ snapshot: Snapshot,
                        startAccessing: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
                        resolveBookmark: (Data) throws -> (url: URL, needsStop: Bool) = { try FolderImporter.resolve(bookmark: $0) }) -> Result {
        var unknown = false
        var sourceFiles: [(relative: String, legacy: String?, isAttachment: Bool)] = []
        for reference in snapshot.references {
            if Task.isCancelled { return .unknown }
            switch reference {
            case .owned(let relative):
                guard let path = LibraryPathResolver.assetPath(relative: relative, assetsRoot: snapshot.assetsRoot) else {
                    unknown = true; continue
                }
                switch file(URL(fileURLWithPath: path)) {
                case .missing: return .missing
                case .unknown: unknown = true
                case .available: break
                }
            case .source(let relative, let legacy): sourceFiles.append((relative, legacy, false))
            case .attachment(let relative): sourceFiles.append((relative, nil, true))
            }
        }
        guard !sourceFiles.isEmpty else { return unknown ? .unknown : .available }
        guard let source = snapshot.source else { return .unknown }
        let fallback = URL(fileURLWithPath: source.sourceRootPath, isDirectory: true)
        var restored: (url: URL, needsStop: Bool)?
        var invalidBookmark = false
        if let bookmark = source.bookmark {
            do { restored = try resolveBookmark(bookmark) }
            catch {
                let error = error as NSError
                // A corrupt bookmark is an unusable saved link. Other errors
                // may be temporary provider failures and remain inconclusive.
                invalidBookmark = bookmark.isEmpty || (error.domain == NSCocoaErrorDomain
                    && error.code == NSFileReadCorruptFileError)
            }
        }
        var root = restored?.url ?? fallback
        var needsStop = restored?.needsStop ?? startAccessing(root)
        if root.standardizedFileURL != fallback.standardizedFileURL,
           !FileManager.default.fileExists(atPath: root.path),
           FileManager.default.fileExists(atPath: fallback.path) {
            if needsStop { root.stopAccessingSecurityScopedResource() }
            root = fallback
            needsStop = startAccessing(root)
        }
        if !FileManager.default.fileExists(atPath: root.path),
           let relocated = relocatedLocalRoot(root.path, appHome: snapshot.appHome) {
            if needsStop { root.stopAccessingSecurityScopedResource() }
            root = URL(fileURLWithPath: relocated, isDirectory: true)
            needsStop = false // The candidate is inside this App's Documents.
        }
        defer { if needsStop { root.stopAccessingSecurityScopedResource() } }
        // A denied external bookmark can look like ENOENT. Do not turn an
        // ungranted security scope into a broken-link claim.
        guard needsStop || isInside(root.path, snapshot.appHome) else {
            return invalidBookmark ? .missing : .unknown
        }
        let workDirectory = LibraryPathResolver.workDirectory(root: root.path,
            workRelativePath: source.workRelativePath, grouping: source.grouping)
        let attachmentDirectory = source.includeSourceRootAttachments && WorkAttachmentFinder.isLegacyFormatFolder(source.workRelativePath)
            ? root.path : workDirectory
        for (relative, legacy, isAttachment) in sourceFiles {
            if Task.isCancelled { return .unknown }
            if let legacy, (isInside(legacy, root.path) || isInside(legacy, snapshot.appHome)),
               file(URL(fileURLWithPath: legacy)) == .available { continue }
            guard let path = LibraryPathResolver.assetPath(relative: relative,
                assetsRoot: isAttachment ? attachmentDirectory : workDirectory) else {
                unknown = true; continue
            }
            switch file(URL(fileURLWithPath: path)) {
            case .missing: return .missing
            case .unknown: unknown = true
            case .available: break
            }
        }
        return unknown ? .unknown : .available
    }

    private static func relocatedLocalRoot(_ stored: String, appHome: String) -> String? {
        let path = URL(fileURLWithPath: stored).standardizedFileURL.resolvingSymlinksInPath().path
        let current = URL(fileURLWithPath: appHome).standardizedFileURL.resolvingSymlinksInPath()
        guard let documents = path.range(of: "/Documents/"),
              UUID(uuidString: current.lastPathComponent) != nil else { return nil }
        let previous = URL(fileURLWithPath: String(path[..<documents.lowerBound]), isDirectory: true)
        // Only a previous sibling App container is a migration candidate. An
        // arbitrary provider folder named Documents must not be reinterpreted.
        guard UUID(uuidString: previous.lastPathComponent) != nil,
              previous.path != current.path,
              previous.deletingLastPathComponent().path == current.deletingLastPathComponent().path else { return nil }
        return LibraryPathResolver.reanchor(storedRoot: path,
            currentDocumentsRoot: current.appendingPathComponent("Documents", isDirectory: true).path)
    }

    private static func isInside(_ path: String, _ root: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        return normalized == base || normalized.hasPrefix(base + "/")
    }

    private static func file(_ url: URL) -> Result {
        do {
            // Metadata only: never open the audio or request cloud downloading.
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isUbiquitousItemKey])
            if values.isUbiquitousItem == true { return .available }
            return values.isRegularFile == true ? .available : .unknown
        } catch {
            let error = error as NSError
            let notFound = (error.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) ||
                (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
            guard notFound else { return .unknown }
            // Older iCloud providers expose an evicted item as a sibling stub.
            let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
            if FileManager.default.fileExists(atPath: placeholder.path) { return .unknown }
            return .missing
        }
    }
}

@MainActor
final class WorkFileLinkStatusCache: ObservableObject {
    @Published private(set) var refreshRevision: UInt = 0
    private struct Key: Equatable {
        let sourceID: Int64
        let contentRevision: UInt
        let refreshRevision: UInt
    }
    private struct Entry { let key: Key; let result: WorkFileLinkProbe.Result }
    private struct Pending { let key: Key; let task: Task<WorkFileLinkProbe.Result, Never> }
    private var entries: [Int64: Entry] = [:]
    private var pending: [Int64: Pending] = [:]
    private var foreground: AnyCancellable?

    init() {
        foreground = NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in self?.invalidate() }
    }

    func invalidate() {
        for value in pending.values { value.task.cancel() }
        pending.removeAll(); entries.removeAll()
        refreshRevision &+= 1
    }

    func result(for work: WorkRecord, store: LibraryStore) async -> WorkFileLinkProbe.Result {
        let key = Key(sourceID: work.sourceID, contentRevision: store.contentRevision, refreshRevision: refreshRevision)
        if let entry = entries[work.id], entry.key == key { return entry.result }
        if let operation = pending[work.id], operation.key == key { return await operation.task.value }
        pending[work.id]?.task.cancel()
        guard let repo = store.repository, let assets = try? WorkAssetImporter.directory(),
              let tracks = try? repo.tracks(workID: work.id),
              let attachments = try? repo.attachmentRecords(workID: work.id) else { return .unknown }
        // Remote availability is checked by the network adapter at playback time;
        // a disconnected NAS is not a missing local folder and must not trigger local relinking.
        let isNetworkSource = store.sources.contains { $0.id == work.sourceID && [.smb, .http, .webdav].contains($0.type) }
        var references = tracks.compactMap { track -> WorkFileLinkProbe.Reference? in
            if let asset = track.assetRelativePath { return .owned(asset) }
            guard !isNetworkSource else { return nil }
            let relative = track.relativePath.flatMap { $0.isEmpty ? nil : $0 }
            return .source(relative: relative ?? track.fileName, legacyAbsolute: relative == nil ? track.filePath : nil)
        }
        references += attachments.filter { $0.attachment.kind == .video }.compactMap { record in
            if let asset = record.assetRelativePath { return .owned(asset) }
            return isNetworkSource ? nil : .attachment(relative: record.attachment.relativePath)
        }
        if isNetworkSource && references.isEmpty { return .unknown }
        let snapshot = WorkFileLinkProbe.Snapshot(assetsRoot: assets.path, appHome: NSHomeDirectory(),
            source: store.attachmentSource(for: work), references: references)
        let operation = Task.detached(priority: .utility) { WorkFileLinkProbe.inspect(snapshot) }
        pending[work.id] = Pending(key: key, task: operation)
        let inspected = await operation.value
        let result: WorkFileLinkProbe.Result = isNetworkSource && inspected == .available ? .unknown : inspected
        guard pending[work.id]?.key == key else { return .unknown }
        pending[work.id] = nil
        guard store.contentRevision == key.contentRevision, refreshRevision == key.refreshRevision else { return .unknown }
        entries[work.id] = Entry(key: key, result: result)
        return result
    }
}
