import Foundation
import HibikiCore

func runCallProfileSuites(_ h: Harness) {
    func test(_ name: String, _ body: () throws -> Void) {
        h.test(name) { do { try body() } catch { h.expect(false, "测试抛出错误：\(error)") } }
    }
    func snapshot(_ db: SQLiteDatabase) throws -> [String: [SQLRow]] {
        var result: [String: [SQLRow]] = [:]
        for row in try db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") {
            let name = row.string("name")!
            result[name] = try db.query("SELECT * FROM \"\(name)\" ORDER BY rowid")
        }
        return result
    }
    func rejects(_ db: SQLiteDatabase, error expected: CallProfileEditingError? = nil,
                 _ operation: () throws -> Void) throws {
        let before = try snapshot(db)
        do { try operation(); h.expect(false, "无效操作应被拒绝") }
        catch {
            if let expected { h.expectEqual(error as? CallProfileEditingError, expected, "错误类型") }
            else { h.expect(true, "拒绝无效操作") }
        }
        h.expectEqual(try snapshot(db), before, "失败后所有表和编号序列完全不变")
    }
    func makeLibrary() throws -> (db: SQLiteDatabase, library: LibraryRepository,
                                  source: Int64, work: Int64, creator: Int64) {
        let db = try SQLiteDatabase.inMemory(), library = LibraryRepository(database: db)
        try library.prepare()
        let source = try library.saveSource(LibrarySource(name: "通话测试", rootPath: "/call-profile-test"))
        let creator = try library.saveCreator(CreatorRecord(name: "原作者", avatarAssetPath: "Covers/creator.png",
            coverMode: .image, coverAssetPath: "Covers/banner.png", note: "作者原备注"))
        let work = try library.upsertWork(WorkRecord(title: "原作品", folderPath: "/call-profile-test/work",
            folderRelativePath: "work", sourceID: source, libraryKind: .personal, creatorID: creator))
        return (db, library, source, work, creator)
    }

    h.suite("通话资料、独立取景与迁移保护") {
        test("通话名称按角色、唯一作者或声优、作品、通话中回退，不猜多人身份") {
            func name(_ role: String? = nil, _ personal: Bool = true,
                      _ creators: [String] = [], _ performers: [String] = [], _ title: String = "作品") -> String {
                CallDisplayNamePolicy.resolve(roleName: role, isPersonal: personal,
                    creatorNames: creators, performerNames: performers, workTitle: title)
            }
            h.expectEqual(name(" 角色 \n", true, ["作者"], [], "标题"), "角色", "角色名优先并去首尾空白")
            h.expectEqual(name(nil, true, [" 作者 "]), "作者", "个人音声唯一作者")
            h.expectEqual(name(" ", false, ["忽略"], [" 声优 "]), "声优", "合集唯一声优")
            h.expectEqual(name(nil, true, [], ["不能借用声优"]), "作品", "个人音声不借用声优名单")
            h.expectEqual(name(nil, false, ["不能借用作者"]), "作品", "合集不借用创作者名单")
            h.expectEqual(name(nil, true, ["甲", "乙"]), "作品", "多人不猜当前说话者")
            h.expectEqual(name(nil, false, [], ["同名", "同名"]), "作品", "同名多人也不去重后冒充唯一")
            h.expectEqual(name(nil, true, ["", " 甲 ", "\n"]), "甲", "空白条目不充当人物")
            h.expectEqual(name(nil, true, [], [], " \n"), "通话中", "全部为空时的显示兜底")
            h.expectEqual(name(nil, false, [], [], " 标题 "), "标题", "作品标题去首尾空白")
        }

        test("v19完整资料升级只增加通话表和触发器，旧表逐行逐字段不变") {
            let f = try RelinkingFixture(version: 19)
            let creator = try f.library.saveCreator(CreatorRecord(name: "旧作者",
                avatarAssetPath: "Covers/old-avatar.png", coverMode: .image,
                coverAssetPath: "Covers/old-cover.png", note: "旧备注"))
            try f.db.execute("UPDATE work SET library_kind = 'personal', creator_id = ? WHERE id = ?",
                             [.integer(creator), .integer(f.workID)])
            try f.db.execute("""
                INSERT INTO work_direct_link(work_id, site, source_url, metadata_json, created_at)
                VALUES (?, 'direct', 'https://example.invalid/original', '{"title":"旧导入资料"}', 1234)
                """, [.integer(f.workID)])
            try f.library.appendOwnedMedia(workID: f.workID, tracks: [], attachments: [
                WorkAttachmentRecord(workID: f.workID,
                    attachment: WorkAttachment(relativePath: "Movie.mp4", kind: .video, byteCount: 789),
                    assetRelativePath: "Attachments/old-movie.mp4")
            ])
            let video = try f.library.attachmentRecords(workID: f.workID).first { $0.attachment.kind == .video }!
            try f.db.execute("INSERT INTO video_playback_position(attachment_id, position_ms, updated_at) VALUES (?, 9876, 4567)",
                             [.integer(video.id)])
            let before = try snapshot(f.db)
            let oldSchema = try f.db.query("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY name")
            let oldNames = Set(oldSchema.compactMap { $0.string("name") })
            let throughCallProfiles = Schema.migrations.filter { $0.version <= 20 }
            h.expectEqual(try f.db.migrate(throughCallProfiles), 1, "只执行 v20")
            h.expectEqual(f.db.userVersion, 20, "版本号")
            let after = try snapshot(f.db)
            h.expectEqual(Set(after.keys).subtracting(before.keys), Set(["call_profile"]), "只增加一个业务表")
            for (table, rows) in before { h.expectEqual(after[table], rows, "旧表 \(table) 完整保留") }
            let newSchema = try f.db.query("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY name")
            h.expectEqual(newSchema.filter { oldNames.contains($0.string("name")!) }, oldSchema, "旧表、索引、触发器定义不变")
            h.expectEqual(try f.db.migrate(throughCallProfiles), 0, "再次启动无需迁移")
            h.expectEqual(try snapshot(f.db), after, "再次启动不制造空白通话资料")
            h.expect(try f.db.query("PRAGMA foreign_key_check").isEmpty, "外键完好")
            h.expectEqual(try f.db.query("PRAGMA integrity_check").first?.string("integrity_check"), "ok", "结构完好")
        }

        test("v20后段失败回滚新表和已建触发器，v19资料与版本保留") {
            let f = try RelinkingFixture(version: 19)
            try f.db.execute("CREATE TRIGGER delete_creator_call_profile AFTER DELETE ON creator BEGIN SELECT 1; END")
            let before = try f.db.query("SELECT * FROM sqlite_master ORDER BY name")
            try rejects(f.db) { try f.library.prepare() }
            h.expectEqual(f.db.userVersion, 19, "失败不推进版本")
            h.expectEqual(try f.db.query("SELECT * FROM sqlite_master ORDER BY name"), before, "全部迁移结构回滚")
        }

        test("未设置资料时不写库，三种默认语义和黑底分别保留") {
            let f = try makeLibrary(), before = try snapshot(f.db)
            h.expectNil(try f.library.callProfile(ownerKind: .work, id: f.work), "作品未覆盖")
            h.expectNil(try f.library.callProfile(ownerKind: .creator, id: f.creator), "作者未设置")
            h.expectNil(try f.library.callProfile(ownerKind: .localUser, id: 0), "我的显示未设置")
            let work = CallProfile.defaults(for: .work), creator = CallProfile.defaults(for: .creator)
            let local = CallProfile.defaults(for: .localUser)
            h.expectEqual(work.avatarMode, .inherit, "作品头像继承")
            h.expectEqual(work.backgroundMode, .inherit, "作品背景继承")
            h.expect(work.prefersWorkVideo, "默认优先作品视频")
            h.expectEqual(creator.avatarMode, .inherit, "作者默认用自身头像")
            h.expectEqual(creator.backgroundMode, .none, "作者默认无背景")
            h.expectEqual(local.avatarMode, .none, "我的头像默认空")
            h.expectEqual(local.backgroundMode, .none, "我的显示默认黑底")
            h.expectEqual(local.avatarFraming.fillMode, .black, "不默认模糊填边")
            h.expectEqual(work.avatarFraming, CallFraming(), "默认完整显示原图")
            h.expectEqual(try snapshot(f.db), before, "读默认设置不写任何表")
        }

        test("作品与作者即使相同ID也独立保存，角色名不覆盖资料，none不变为inherit") {
            let f = try makeLibrary()
            h.expectEqual(f.work, f.creator, "fixture验证复合身份键")
            let before = try snapshot(f.db).filter { $0.key != "call_profile" }
            let work = CallProfile(roleName: "  仅通话角色\n", avatarMode: .custom,
                avatarAssetPath: "CallProfiles/original-avatar.png",
                avatarFraming: CallFraming(zoom: 0.25, offsetX: -1, offsetY: 1, fillMode: .blur),
                backgroundMode: .none, backgroundAssetPath: "CallProfiles/remembered-video.mov",
                backgroundKind: .video,
                backgroundFraming: CallFraming(zoom: 5, offsetX: 1, offsetY: -1), prefersWorkVideo: false)
            var creator = CallProfile.defaults(for: .creator)
            creator.roleName = "作者通话名"
            creator.backgroundMode = .custom
            creator.backgroundAssetPath = "CallProfiles/creator-video.mp4"
            creator.backgroundKind = .video
            var local = CallProfile.defaults(for: .localUser)
            local.roleName = "我的显示名"
            local.avatarMode = .custom
            local.avatarAssetPath = "CallProfiles/local-original.png"
            try f.library.saveCallProfile(work, ownerKind: .work, id: f.work)
            try f.library.saveCallProfile(creator, ownerKind: .creator, id: f.creator)
            try f.library.saveCallProfile(local, ownerKind: .localUser, id: 0)
            let reopened = LibraryRepository(database: f.db)
            h.expectEqual(try reopened.callProfile(ownerKind: .work, id: f.work), work, "作品全部字段原样重读")
            h.expectEqual(try reopened.callProfile(ownerKind: .creator, id: f.creator), creator, "作者全部字段原样重读")
            h.expectEqual(try reopened.callProfile(ownerKind: .localUser, id: 0), local, "我的显示原样重读")
            h.expectEqual(try snapshot(f.db).filter { $0.key != "call_profile" }, before, "旧元数据、时间戳和其他所有表不变")
            h.expectEqual(try f.db.query("SELECT * FROM call_profile").count, 3, "同号不同owner各一条")
            var changed = work
            changed.backgroundMode = .inherit
            changed.avatarFraming.zoom = 2
            try f.library.saveCallProfile(changed, ownerKind: .work, id: f.work)
            h.expectEqual(try f.library.callProfile(ownerKind: .work, id: f.work)?.backgroundFraming,
                          work.backgroundFraming, "修改头像取景不改背景取景")
            h.expectEqual(try f.library.callProfile(ownerKind: .creator, id: f.creator), creator, "作品编辑不改作者默认")
            h.expectEqual(try f.db.query("SELECT * FROM call_profile").count, 3, "更新不复制记录")
        }

        test("相同原图可独立取景，切换头像背景模式不抹掉原图和隐藏设置") {
            let f = try makeLibrary()
            var profile = CallProfile(avatarMode: .custom, avatarAssetPath: "CallProfiles/shared.png",
                avatarFraming: CallFraming(zoom: 2, offsetX: 0.25), backgroundMode: .avatar,
                backgroundAssetPath: "CallProfiles/previous-background.png",
                backgroundFraming: CallFraming(zoom: 0.75, offsetY: -0.5, fillMode: .blur))
            try f.library.saveCallProfile(profile, ownerKind: .work, id: f.work)
            h.expectEqual(try f.library.callProfile(ownerKind: .work, id: f.work), profile, "头像模式背景拥有独立取景")
            profile.avatarMode = .none
            profile.backgroundMode = .none
            try f.library.saveCallProfile(profile, ownerKind: .work, id: f.work)
            h.expectEqual(try f.library.callProfile(ownerKind: .work, id: f.work), profile, "明确关闭仍保存原始路径和取景")
            h.expectEqual(try f.library.allCallProfileAssetPaths(),
                Set(["CallProfiles/shared.png", "CallProfiles/previous-background.png"]), "关闭状态原图仍需保留")
        }

        test("不要求资源文件当前存在，删除单份资料不影响其他引用或旧资料") {
            let f = try makeLibrary()
            let profile = CallProfile(avatarMode: .custom, avatarAssetPath: "CallProfiles/not-present.png",
                backgroundMode: .custom, backgroundAssetPath: "CallProfiles/not-present.mp4", backgroundKind: .video)
            try f.library.saveCallProfile(profile, ownerKind: .work, id: f.work)
            var creator = CallProfile.defaults(for: .creator)
            creator.avatarMode = .custom
            creator.avatarAssetPath = profile.avatarAssetPath
            try f.library.saveCallProfile(creator, ownerKind: .creator, id: f.creator)
            h.expectEqual(try f.library.callProfile(ownerKind: .work, id: f.work), profile, "资源缺失不自动reset")
            let oldTables = try snapshot(f.db).filter { $0.key != "call_profile" }
            try f.library.removeCallProfile(ownerKind: .work, id: f.work)
            try f.library.removeCallProfile(ownerKind: .work, id: f.work)
            h.expectNil(try f.library.callProfile(ownerKind: .work, id: f.work), "删除覆盖后回到未设置")
            h.expectEqual(try f.library.callProfile(ownerKind: .creator, id: f.creator), creator, "共享引用仍完整")
            h.expectEqual(try f.library.allCallProfileAssetPaths(), Set(["CallProfiles/not-present.png"]), "仍保留另一owner引用")
            h.expectEqual(try snapshot(f.db).filter { $0.key != "call_profile" }, oldTables, "清理通话行不改旧库数据")
        }

        test("无效owner和不存在实体不能保存，错误不会改任何表") {
            let f = try makeLibrary()
            for (kind, id) in [(CallProfileOwnerKind.work, Int64(0)), (.work, -1), (.work, 999),
                               (.creator, 0), (.creator, -1), (.creator, 999), (.localUser, -1), (.localUser, 1)] {
                try rejects(f.db, error: .invalidOwner) {
                    try f.library.saveCallProfile(.defaults(for: kind), ownerKind: kind, id: id)
                }
            }
            try rejects(f.db, error: .invalidOwner) { _ = try f.library.callProfile(ownerKind: .localUser, id: 1) }
            try rejects(f.db, error: .invalidOwner) { try f.library.removeCallProfile(ownerKind: .work, id: 0) }
            h.expectNil(try f.library.callProfile(ownerKind: .work, id: 999), "已删除正ID允许读空")
        }

        test("所有路径包括隐藏路径都拒绝越界、绝对、空段与NUL，custom必须有文件引用") {
            let f = try makeLibrary()
            try f.library.saveCallProfile(CallProfile(roleName: "保留旧设置"), ownerKind: .work, id: f.work)
            for path in ["", "/tmp/file.png", "../outside.png", "CallProfiles/../outside.png",
                         "./file.png", "CallProfiles//file.png", "CallProfiles/", "CallProfiles/a\0.png"] {
                for isAvatar in [true, false] {
                    var invalid = CallProfile(avatarMode: .none, backgroundMode: .none)
                    if isAvatar { invalid.avatarAssetPath = path } else { invalid.backgroundAssetPath = path }
                    try rejects(f.db, error: .invalidPath) {
                        try f.library.saveCallProfile(invalid, ownerKind: .work, id: f.work)
                    }
                }
            }
            for profile in [CallProfile(avatarMode: .custom), CallProfile(backgroundMode: .custom)] {
                try rejects(f.db, error: .missingCustomAsset) {
                    try f.library.saveCallProfile(profile, ownerKind: .work, id: f.work)
                }
            }
        }

        test("头像和背景分别校验有限取景范围，不夹取错误数值后静默覆盖") {
            let f = try makeLibrary()
            let invalidFramings = [CallFraming(zoom: 0.249), CallFraming(zoom: 5.001),
                CallFraming(zoom: .infinity), CallFraming(zoom: .nan),
                CallFraming(offsetX: -1.001), CallFraming(offsetX: 1.001),
                CallFraming(offsetX: .infinity), CallFraming(offsetX: .nan),
                CallFraming(offsetY: -1.001), CallFraming(offsetY: 1.001),
                CallFraming(offsetY: -.infinity), CallFraming(offsetY: .nan)]
            for framing in invalidFramings {
                for isAvatar in [true, false] {
                    var profile = CallProfile()
                    if isAvatar { profile.avatarFraming = framing } else { profile.backgroundFraming = framing }
                    try rejects(f.db, error: .invalidFraming) {
                        try f.library.saveCallProfile(profile, ownerKind: .work, id: f.work)
                    }
                }
            }
        }

        test("作者不能继续继承背景，我的显示不继承且保持黑边") {
            let f = try makeLibrary()
            try rejects(f.db, error: .invalidMode) {
                try f.library.saveCallProfile(CallProfile(), ownerKind: .creator, id: f.creator)
            }
            var inheritAvatar = CallProfile.defaults(for: .localUser)
            inheritAvatar.avatarMode = .inherit
            var inheritBackground = CallProfile.defaults(for: .localUser)
            inheritBackground.backgroundMode = .inherit
            var blurAvatar = CallProfile.defaults(for: .localUser)
            blurAvatar.avatarFraming.fillMode = .blur
            var blurBackground = CallProfile.defaults(for: .localUser)
            blurBackground.backgroundFraming.fillMode = .blur
            for profile in [inheritAvatar, inheritBackground, blurAvatar, blurBackground] {
                try rejects(f.db, error: .invalidMode) {
                    try f.library.saveCallProfile(profile, ownerKind: .localUser, id: 0)
                }
            }
        }

        test("删除作品与作者仅清自己的通话资料，同ID和其他作品及我的资料保留") {
            let f = try makeLibrary()
            let second = try f.library.upsertWork(WorkRecord(title: "另一作品", folderPath: "/call-profile-test/second",
                folderRelativePath: "second", sourceID: f.source, libraryKind: .personal, creatorID: f.creator))
            try f.library.saveCallProfile(CallProfile(roleName: "第一角色"), ownerKind: .work, id: f.work)
            let secondProfile = CallProfile(roleName: "第二角色", backgroundMode: .none)
            try f.library.saveCallProfile(secondProfile, ownerKind: .work, id: second)
            let creator = CallProfile.defaults(for: .creator), local = CallProfile.defaults(for: .localUser)
            try f.library.saveCallProfile(creator, ownerKind: .creator, id: f.creator)
            try f.library.saveCallProfile(local, ownerKind: .localUser, id: 0)
            try f.db.execute("DELETE FROM work WHERE id = ?", [.integer(f.work)])
            h.expectNil(try f.library.callProfile(ownerKind: .work, id: f.work), "作品触发器清理资料")
            h.expectEqual(try f.library.callProfile(ownerKind: .creator, id: f.creator), creator, "同ID作者不受影响")
            try f.db.execute("DELETE FROM creator WHERE id = ?", [.integer(f.creator)])
            h.expectNil(try f.library.callProfile(ownerKind: .creator, id: f.creator), "作者触发器清理资料")
            h.expectEqual(try f.library.callProfile(ownerKind: .work, id: second), secondProfile, "作者删除不清作品覆盖")
            h.expectNil(try f.library.work(id: second)?.creatorID, "原外键的SET NULL保持")
            try f.db.execute("DELETE FROM source WHERE id = ?", [.integer(f.source)])
            h.expectNil(try f.library.callProfile(ownerKind: .work, id: second), "删除源级联作品也清资料")
            h.expectEqual(try f.library.callProfile(ownerKind: .localUser, id: 0), local, "我的显示独立保留")
            h.expectEqual(try f.db.query("SELECT * FROM call_profile").count, 1, "无孤儿资料")
            h.expect(try f.db.query("PRAGMA foreign_key_check").isEmpty, "删除后外键一致")
        }

        test("损坏JSON或非法持久路径不会自动重置，也不会返回不完整的资源保留集合") {
            let f = try makeLibrary()
            let invalidProfiles = ["{broken", "{}", "{\"avatarMode\":\"unknown\"}"]
            for json in invalidProfiles {
                try f.db.execute("""
                    INSERT OR REPLACE INTO call_profile(owner_kind, owner_id, profile_json, updated_at)
                    VALUES ('work', ?, ?, 123)
                    """, [.integer(f.work), .text(json)])
                try rejects(f.db, error: .invalidStoredProfile) {
                    _ = try f.library.callProfile(ownerKind: .work, id: f.work)
                }
                try rejects(f.db, error: .invalidStoredProfile) { _ = try f.library.allCallProfileAssetPaths() }
            }
            var invalidPath = CallProfile()
            invalidPath.avatarAssetPath = "../outside.png"
            let json = String(decoding: try JSONEncoder().encode(invalidPath), as: UTF8.self)
            try f.db.execute("UPDATE call_profile SET profile_json = ? WHERE owner_kind = 'work' AND owner_id = ?",
                             [.text(json), .integer(f.work)])
            try rejects(f.db, error: .invalidStoredProfile) { _ = try f.library.callProfile(ownerKind: .work, id: f.work) }
            try rejects(f.db, error: .invalidStoredProfile) { _ = try f.library.allCallProfileAssetPaths() }
        }
    }
}
