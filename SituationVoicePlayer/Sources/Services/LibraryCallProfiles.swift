import Foundation
import AVFoundation

struct ResolvedCallAppearance {
    var name: String
    var avatarURL: URL?
    var avatarFraming: CallFraming
    var backgroundURL: URL?
    var backgroundKind: CallBackgroundKind
    var backgroundFraming: CallFraming
    var prefersWorkVideo: Bool
}

extension LibraryStore {
    /// Edit the owner of the resolved background, preserving inherited source/framing metadata.
    func setCallSpatialEffect(_ enabled: Bool, for work: WorkRecord) throws {
        let own = try callProfile(ownerKind: .work, id: work.id)
        let usesCreator = work.libraryKind == .personal && own.backgroundMode == .inherit
        let kind: CallProfileOwnerKind = usesCreator ? .creator : .work
        guard let id = usesCreator ? work.creatorID : work.id else { throw LibraryEditingError.unavailable }
        var profile = try callProfile(ownerKind: kind, id: id)
        profile.backgroundFraming.spatialEffectEnabled = enabled
        try saveCallProfile(profile, ownerKind: kind, id: id)
    }

    func callProfile(ownerKind: CallProfileOwnerKind, id: Int64) throws -> CallProfile {
        guard let repository else { throw LibraryEditingError.unavailable }
        return try repository.callProfile(ownerKind: ownerKind, id: id) ?? .defaults(for: ownerKind)
    }

    func saveCallProfile(_ profile: CallProfile, ownerKind: CallProfileOwnerKind, id: Int64) throws {
        guard let repository else { throw LibraryEditingError.unavailable }
        let old = try repository.callProfile(ownerKind: ownerKind, id: id)
        try repository.saveCallProfile(profile, ownerKind: ownerKind, id: id)
        removeUnreferencedCallAssets([old?.avatarAssetPath, old?.backgroundAssetPath].compactMap { $0 })
        reload()
    }

    /// Never delete a saved shared image just because one editor stopped using it.
    func removeUnreferencedCallAssets(_ candidates: [String]) {
        guard !candidates.isEmpty, let repository else { return }
        do {
            var retained = try repository.allCallProfileAssetPaths()
            let authors = try repository.creators()
            retained.formUnion(authors.flatMap { [$0.avatarAssetPath, $0.coverAssetPath].compactMap { $0 } })
            let works = try repository.works()
            retained.formUnion(works.compactMap(\.coverAssetPath))
            for work in works {
                retained.formUnion(try repository.tracks(workID: work.id).compactMap(\.assetRelativePath))
                retained.formUnion(try repository.attachmentRecords(workID: work.id).compactMap(\.assetRelativePath))
            }
            for value in Set(candidates) where !retained.contains(value) { WorkAssetImporter.remove(value) }
        } catch {
            // A failed reference audit must retain files, never guess that they are unused.
            DebugLog.write("暂保留通话图片，资源引用核对失败：\(error.localizedDescription)")
        }
    }

    func callAssetURL(_ relative: String?) -> URL? {
        guard let relative, let path = WorkAssetImporter.path(for: relative) else { return nil }
        if relative.hasPrefix("Covers/") { return WorkAssetImporter.originalImageForCropping(at: path) }
        return URL(fileURLWithPath: path)
    }

    func resolvedCreatorCallAppearance(_ author: CreatorRecord) throws -> ResolvedCallAppearance {
        let profile = try callProfile(ownerKind: .creator, id: author.id)
        let avatar: URL?
        switch profile.avatarMode {
        case .inherit: avatar = callAssetURL(author.avatarAssetPath)
        case .custom: avatar = callAssetURL(profile.avatarAssetPath)
        case .none: avatar = nil
        }
        let background: URL?
        switch profile.backgroundMode {
        case .custom: background = callAssetURL(profile.backgroundAssetPath)
        case .avatar: background = avatar
        case .none, .inherit: background = nil
        }
        return ResolvedCallAppearance(name: author.name, avatarURL: avatar, avatarFraming: profile.avatarFraming,
            backgroundURL: background, backgroundKind: profile.backgroundMode == .avatar ? .image : profile.backgroundKind,
            backgroundFraming: profile.backgroundFraming, prefersWorkVideo: true)
    }

    func resolvedCallAppearance(for work: WorkRecord) throws -> ResolvedCallAppearance {
        let profile = try callProfile(ownerKind: .work, id: work.id)
        let author = work.libraryKind == .personal ? creator(id: work.creatorID) : nil
        let workCover = coverPath(forWorkID: work.id).map { WorkAssetImporter.originalImageForCropping(at: $0) }
        let inherited = try author.map { try callProfile(ownerKind: .creator, id: $0.id) }
        let authorAvatar: URL?
        switch inherited?.avatarMode ?? .inherit {
        case .inherit: authorAvatar = callAssetURL(author?.avatarAssetPath)
        case .custom: authorAvatar = callAssetURL(inherited?.avatarAssetPath)
        case .none: authorAvatar = nil
        }
        let avatar: URL?
        let avatarFrame: CallFraming
        switch profile.avatarMode {
        case .inherit:
            avatar = work.libraryKind == .collection ? workCover : authorAvatar
            avatarFrame = work.libraryKind == .collection ? profile.avatarFraming : (inherited?.avatarFraming ?? CallFraming())
        case .custom:
            avatar = callAssetURL(profile.avatarAssetPath)
            avatarFrame = profile.avatarFraming
        case .none:
            avatar = nil
            avatarFrame = profile.avatarFraming
        }
        let inheritsCover = work.libraryKind == .collection && profile.backgroundMode == .inherit
        let backgroundProfile = profile.backgroundMode == .inherit && !inheritsCover ? inherited : profile
        let background: URL?
        if inheritsCover { background = workCover }
        else {
            switch backgroundProfile?.backgroundMode ?? .none {
            case .custom: background = callAssetURL(backgroundProfile?.backgroundAssetPath)
            case .avatar: background = profile.backgroundMode == .inherit ? authorAvatar : avatar
            case .none, .inherit: background = nil
            }
        }
        return ResolvedCallAppearance(
            name: CallDisplayNamePolicy.resolve(roleName: profile.roleName, isPersonal: work.libraryKind == .personal,
                creatorNames: author.map { [$0.name] } ?? [], performerNames: work.seiyuuNames, workTitle: work.title),
            avatarURL: avatar, avatarFraming: avatarFrame, backgroundURL: background,
            backgroundKind: inheritsCover || backgroundProfile?.backgroundMode == .avatar ? .image : (backgroundProfile?.backgroundKind ?? .image),
            backgroundFraming: backgroundProfile?.backgroundFraming ?? CallFraming(), prefersWorkVideo: profile.prefersWorkVideo)
    }
}

extension WorkAssetImporter {
    static func copyCallBackgroundVideo(from source: URL) async throws -> String {
        guard WorkAttachmentFinder.kind(forExtension: source.pathExtension) == .video else {
            throw WorkAssetImportError.unsupportedFile(source.lastPathComponent)
        }
        let operation = Task.detached(priority: .userInitiated) {
            let record = try copyAttachment(from: source, workID: 0)
            guard let relative = record.assetRelativePath else { throw CocoaError(.fileReadCorruptFile) }
            do {
                try Task.checkCancellation()
                guard let path = path(for: relative) else { throw CocoaError(.fileReadCorruptFile) }
                withExtendedLifetime(try await PreparedWorkVideo.prepare(URL(fileURLWithPath: path))) {}
                try Task.checkCancellation()
                return relative
            } catch { remove(relative); throw error }
        }
        return try await withTaskCancellationHandler {
            let relative = try await operation.value
            if Task.isCancelled { remove(relative); throw CancellationError() }
            return relative
        } onCancel: { operation.cancel() }
    }
}
