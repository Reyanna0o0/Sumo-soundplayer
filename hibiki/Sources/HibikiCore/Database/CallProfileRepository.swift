import Foundation

extension LibraryRepository {
    /// An absent record means use defaults/inheritance, not a persisted blank profile.
    public func callProfile(ownerKind: CallProfileOwnerKind, id: Int64) throws -> CallProfile? {
        try validateCallProfileOwnerID(ownerKind, id: id)
        guard let row = try db.query("SELECT profile_json FROM call_profile WHERE owner_kind = ? AND owner_id = ?",
                                     [.text(ownerKind.rawValue), .integer(id)]).first else { return nil }
        return try decodeCallProfile(row.string("profile_json"), ownerKind: ownerKind)
    }

    /// Only the independent call_profile row changes. Inactive custom paths are kept
    /// so switching a mode does not discard the user's original image or framing.
    public func saveCallProfile(_ profile: CallProfile, ownerKind: CallProfileOwnerKind, id: Int64) throws {
        try validateCallProfileOwnerID(ownerKind, id: id)
        try validateCallProfile(profile, ownerKind: ownerKind)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(profile), as: UTF8.self)
        try db.transaction {
            switch ownerKind {
            case .work:
                guard try work(id: id) != nil else { throw CallProfileEditingError.invalidOwner }
            case .creator:
                guard try creator(id: id) != nil else { throw CallProfileEditingError.invalidOwner }
            case .localUser:
                break
            }
            try db.execute("""
                INSERT INTO call_profile(owner_kind, owner_id, profile_json, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(owner_kind, owner_id) DO UPDATE SET
                    profile_json = excluded.profile_json, updated_at = excluded.updated_at
                """, [.text(ownerKind.rawValue), .integer(id), .text(json), SQLValue(Date())])
        }
    }

    /// Removes this setting only. Shared source assets are never deleted here.
    public func removeCallProfile(ownerKind: CallProfileOwnerKind, id: Int64) throws {
        try validateCallProfileOwnerID(ownerKind, id: id)
        try db.execute("DELETE FROM call_profile WHERE owner_kind = ? AND owner_id = ?",
                       [.text(ownerKind.rawValue), .integer(id)])
    }

    /// Includes inactive custom paths: all originals still referenced by a saved
    /// profile must survive asset cleanup. A corrupt record throws rather than
    /// returning an incomplete retention set that could delete a referenced file.
    public func allCallProfileAssetPaths() throws -> Set<String> {
        var paths = Set<String>()
        for row in try db.query("SELECT owner_kind, owner_id, profile_json FROM call_profile") {
            guard let rawKind = row.string("owner_kind"), let kind = CallProfileOwnerKind(rawValue: rawKind),
                  let id = row.int64("owner_id") else { throw CallProfileEditingError.invalidStoredProfile }
            do { try validateCallProfileOwnerID(kind, id: id) }
            catch { throw CallProfileEditingError.invalidStoredProfile }
            let profile = try decodeCallProfile(row.string("profile_json"), ownerKind: kind)
            paths.formUnion([profile.avatarAssetPath, profile.backgroundAssetPath].compactMap { $0 })
        }
        return paths
    }
}

private func validateCallProfileOwnerID(_ kind: CallProfileOwnerKind, id: Int64) throws {
    guard kind == .localUser ? id == 0 : id > 0 else { throw CallProfileEditingError.invalidOwner }
}

private func validateCallProfile(_ profile: CallProfile, ownerKind: CallProfileOwnerKind) throws {
    for framing in [profile.avatarFraming, profile.backgroundFraming] {
        guard framing.zoom.isFinite, (0.25...5).contains(framing.zoom),
              framing.offsetX.isFinite, (-1...1).contains(framing.offsetX),
              framing.offsetY.isFinite, (-1...1).contains(framing.offsetY) else {
            throw CallProfileEditingError.invalidFraming
        }
    }
    for path in [profile.avatarAssetPath, profile.backgroundAssetPath].compactMap({ $0 }) {
        guard !path.contains("\0"),
              LibraryPathResolver.assetPath(relative: path, assetsRoot: "/WorkAssets") != nil else {
            throw CallProfileEditingError.invalidPath
        }
    }
    if (profile.avatarMode == .custom && profile.avatarAssetPath == nil)
        || (profile.backgroundMode == .custom && profile.backgroundAssetPath == nil) {
        throw CallProfileEditingError.missingCustomAsset
    }
    if ownerKind != .work && profile.backgroundMode == .inherit {
        throw CallProfileEditingError.invalidMode
    }
    if ownerKind == .localUser {
        guard profile.avatarMode != .inherit,
              profile.avatarFraming.fillMode == .black,
              profile.backgroundFraming.fillMode == .black else {
            throw CallProfileEditingError.invalidMode
        }
    }
}

private func decodeCallProfile(_ json: String?, ownerKind: CallProfileOwnerKind) throws -> CallProfile {
    guard let json else { throw CallProfileEditingError.invalidStoredProfile }
    do {
        let profile = try JSONDecoder().decode(CallProfile.self, from: Data(json.utf8))
        try validateCallProfile(profile, ownerKind: ownerKind)
        return profile
    } catch {
        // Reading invalid data is never an implicit reset or a write.
        throw CallProfileEditingError.invalidStoredProfile
    }
}
