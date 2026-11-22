import Foundation

/// 数据库表结构（阶段 1 所需部分）。
///
/// 迁移策略：`PRAGMA user_version` + 有序迁移列表，
/// 每次升级只加一条新 `Migration`，已经跑过的自动跳过。
///
/// 设计要点：
/// - 作品去重键是 `(source_id, folder_path)` —— 同一个作品在本地和网盘各有一份时算两条
/// - `rj_code` 单独建索引但不做唯一约束（同一作品可能出现在多个源）
/// - 时间一律存**毫秒整数**，避免时区/浮点问题
public enum Schema {

    public static let currentVersion = 25

    public static var migrations: [Migration] {
        [migration1, migration2, migration3, migration4, migration5, migration6, migration7, migration8, migration9, migration10, migration11, migration12, migration13, migration14, migration15, migration16, migration17, migration18, migration19, migration20, migration21, migration22, migration23, migration24, migration25]
    }

    /// 固定只影响历史保留，不改变来源、版本编号或当前生效版本。
    static let migration25 = Migration(version: 25, sql: """
    ALTER TABLE subtitle_version ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0
        CHECK (is_pinned IN (0, 1));
    CREATE INDEX idx_subtitle_version_number ON subtitle_version(subtitle_track_id, version_no);
    """)

    static let migration24 = Migration(version: 24, sql: """
    ALTER TABLE work ADD COLUMN player_cover_mode TEXT NOT NULL DEFAULT 'original'
        CHECK (player_cover_mode IN ('original', 'fit4x3', 'fill4x3'));
    """)

    static let migration23 = Migration(version: 23, sql: """
    ALTER TABLE playlist_entry ADD COLUMN attachment_id INTEGER REFERENCES work_attachment(id) ON DELETE CASCADE
        CHECK (attachment_id IS NULL OR (track_id IS NULL AND clip_filename IS NULL));
    CREATE UNIQUE INDEX playlist_whole_video ON playlist_entry(group_id, attachment_id) WHERE attachment_id IS NOT NULL;
    """)

    static let migration22 = Migration(version: 22, sql: """
    CREATE TABLE playlist_clip_subtitle (
        entry_id INTEGER PRIMARY KEY REFERENCES playlist_entry(id) ON DELETE CASCADE,
        snapshot_json TEXT NOT NULL
    );
    """)

    static let migration21 = Migration(version: 21, sql: """
    ALTER TABLE track ADD COLUMN title_override TEXT;
    -- Earlier versions saved personal renames on the work. Carry a changed name
    -- to its sole audio track without replacing the scanned name or media path.
    UPDATE track SET title_override = (SELECT title_override FROM work WHERE id = track.work_id)
    WHERE id IN (
        SELECT MIN(t.id) FROM track t JOIN work w ON w.id = t.work_id
        WHERE w.library_kind = 'personal' AND t.is_video = 0
          AND NULLIF(w.title_override, '') IS NOT NULL AND w.title_override <> w.title
        GROUP BY t.work_id HAVING COUNT(*) = 1
    );
    """)

    static let migration20 = Migration(version: 20, sql: """
    CREATE TABLE call_profile (
        owner_kind TEXT NOT NULL CHECK (owner_kind IN ('work', 'creator', 'localUser')),
        owner_id INTEGER NOT NULL,
        profile_json TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (owner_kind, owner_id),
        CHECK ((owner_kind = 'localUser' AND owner_id = 0)
            OR (owner_kind IN ('work', 'creator') AND owner_id > 0))
    );
    CREATE TRIGGER delete_work_call_profile AFTER DELETE ON work BEGIN
        DELETE FROM call_profile WHERE owner_kind = 'work' AND owner_id = OLD.id;
    END;
    CREATE TRIGGER delete_creator_call_profile AFTER DELETE ON creator BEGIN
        DELETE FROM call_profile WHERE owner_kind = 'creator' AND owner_id = OLD.id;
    END;
    """)

    static let migration19 = Migration(version: 19, sql: """
    CREATE TABLE video_playback_position (
        attachment_id INTEGER PRIMARY KEY REFERENCES work_attachment(id) ON DELETE CASCADE,
        position_ms INTEGER NOT NULL CHECK (position_ms >= 0),
        updated_at INTEGER NOT NULL
    );
    """)

    static let migration18 = Migration(version: 18, sql: """
    CREATE TABLE work_direct_link (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        work_id INTEGER NOT NULL REFERENCES work(id) ON DELETE CASCADE,
        site TEXT NOT NULL,
        source_url TEXT NOT NULL,
        metadata_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        UNIQUE(work_id, site, source_url)
    );
    CREATE INDEX idx_direct_link_url ON work_direct_link(site, source_url);
    """)

    // MARK: - v1：媒体库基础表

    static let migration1 = Migration(version: 1, sql: """
    CREATE TABLE IF NOT EXISTS source (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        name          TEXT    NOT NULL,
        type          TEXT    NOT NULL DEFAULT 'local',
        root_path     TEXT,
        bookmark      BLOB,
        enabled       INTEGER NOT NULL DEFAULT 1,
        created_at    INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS work (
        id                     INTEGER PRIMARY KEY AUTOINCREMENT,
        rj_code                TEXT,
        title                  TEXT    NOT NULL,
        circle_name            TEXT,
        seiyuu_name            TEXT,
        cover_path             TEXT,
        folder_path            TEXT    NOT NULL,
        source_id              INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
        rating                 INTEGER NOT NULL DEFAULT 0,
        favorite               INTEGER NOT NULL DEFAULT 0,
        listened               INTEGER NOT NULL DEFAULT 0,
        play_count             INTEGER NOT NULL DEFAULT 0,
        last_played_track_id   INTEGER,
        last_played_position   INTEGER NOT NULL DEFAULT 0,
        last_played_at         INTEGER,
        script_path            TEXT,
        created_at             INTEGER NOT NULL,
        updated_at             INTEGER NOT NULL,
        UNIQUE(source_id, folder_path)
    );

    CREATE INDEX IF NOT EXISTS idx_work_source  ON work(source_id);
    CREATE INDEX IF NOT EXISTS idx_work_rj      ON work(rj_code);
    CREATE INDEX IF NOT EXISTS idx_work_title   ON work(title);
    CREATE INDEX IF NOT EXISTS idx_work_played  ON work(last_played_track_id);

    CREATE TABLE IF NOT EXISTS track (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        work_id       INTEGER NOT NULL REFERENCES work(id) ON DELETE CASCADE,
        file_name     TEXT    NOT NULL,
        file_path     TEXT    NOT NULL,
        relative_path TEXT,
        file_type     TEXT    NOT NULL,
        is_video      INTEGER NOT NULL DEFAULT 0,
        track_index   INTEGER NOT NULL DEFAULT 0,
        title         TEXT,
        duration_ms   INTEGER,
        file_size     INTEGER,
        file_mtime    INTEGER,
        created_at    INTEGER NOT NULL
    );

    CREATE UNIQUE INDEX IF NOT EXISTS idx_track_path ON track(file_path);
    CREATE INDEX IF NOT EXISTS idx_track_work ON track(work_id, track_index);

    CREATE TABLE IF NOT EXISTS app_setting (
        key        TEXT PRIMARY KEY,
        value      TEXT NOT NULL,
        updated_at INTEGER NOT NULL
    );
    """)
}

extension Schema {
    /// Both libraries retain the same work/track identities and all their dependants.
    /// Listening snapshots intentionally have no creator/work foreign keys: history
    /// remains meaningful after an original file or profile is removed.
    static let migration17 = Migration(version: 17, sql: """
    CREATE TABLE creator (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL CHECK (length(trim(name)) > 0),
        avatar_asset_path TEXT,
        cover_mode TEXT NOT NULL DEFAULT 'none' CHECK (cover_mode IN ('none', 'avatar', 'image')),
        cover_asset_path TEXT,
        note TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
    );
    ALTER TABLE work ADD COLUMN library_kind TEXT NOT NULL DEFAULT 'collection'
        CHECK (library_kind IN ('collection', 'personal'));
    ALTER TABLE work ADD COLUMN creator_id INTEGER REFERENCES creator(id) ON DELETE SET NULL;
    CREATE INDEX work_library ON work(library_kind, created_at);
    CREATE INDEX work_creator ON work(creator_id, last_played_at);

    ALTER TABLE play_statistic ADD COLUMN library_kind TEXT DEFAULT 'collection'
        CHECK (library_kind IN ('collection', 'personal'));
    ALTER TABLE play_statistic ADD COLUMN creator_id INTEGER;
    ALTER TABLE play_statistic ADD COLUMN creator_name TEXT;
    ALTER TABLE play_history ADD COLUMN library_kind TEXT DEFAULT 'collection'
        CHECK (library_kind IN ('collection', 'personal'));
    ALTER TABLE play_history ADD COLUMN creator_id INTEGER;
    ALTER TABLE play_history ADD COLUMN creator_name TEXT;
    UPDATE play_statistic SET library_kind = NULL WHERE work_id = 0;
    UPDATE play_history SET library_kind = NULL WHERE work_id = 0;
    CREATE INDEX play_statistic_library ON play_statistic(library_kind, date_key);
    CREATE INDEX play_history_library ON play_history(library_kind, start_date_key);

    DROP TRIGGER preserve_listening_metadata;
    CREATE TRIGGER preserve_listening_metadata BEFORE DELETE ON work BEGIN
        UPDATE play_statistic
        SET title = COALESCE(OLD.title_override, OLD.title),
            circle_name = COALESCE(OLD.circle_name_override, OLD.circle_name),
            seiyuu_names = OLD.seiyuu_names_override, scanned_seiyuu = OLD.seiyuu_name,
            library_kind = OLD.library_kind, creator_id = OLD.creator_id,
            creator_name = (SELECT name FROM creator WHERE id = OLD.creator_id)
        WHERE work_id = OLD.id;
        UPDATE play_history
        SET library_kind = OLD.library_kind, creator_id = OLD.creator_id,
            creator_name = (SELECT name FROM creator WHERE id = OLD.creator_id)
        WHERE work_id = OLD.id;
    END;
    """)
}

extension Schema {
    /// 阅读位置附属于稳定的来源/附件编号，不随字幕版本或 App 容器路径改变。
    static let migration16 = Migration(version: 16, sql: """
    CREATE TABLE subtitle_reading_position (
        subtitle_track_id INTEGER PRIMARY KEY REFERENCES subtitle_track(id) ON DELETE CASCADE,
        payload TEXT NOT NULL,
        updated_at INTEGER NOT NULL
    );
    CREATE TABLE attachment_reading_position (
        attachment_id INTEGER NOT NULL REFERENCES work_attachment(id) ON DELETE CASCADE,
        kind TEXT NOT NULL CHECK (kind IN ('pdf', 'text')),
        payload TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (attachment_id, kind)
    );
    """)
}

extension Schema {
    /// 仅新自动启用的 PDF 底稿允许后来发现的带时间字幕接手。旧来源保持原选择。
    static let migration12 = Migration(version: 12, sql: """
    ALTER TABLE subtitle_track ADD COLUMN prefers_timed_sidecar INTEGER NOT NULL DEFAULT 0;
    """)

    /// 名称和分组显示名独立于扫描结果，稳定 key 和原目录名称不变。
    static let migration10 = Migration(version: 10, sql: """
    ALTER TABLE work ADD COLUMN title_override TEXT;
    ALTER TABLE work ADD COLUMN category_title_overrides TEXT;
    """)
}

extension Schema {
    /// 手动资料独立于扫描结果；自选文件只存相对 App 自有目录的路径。
    static let migration9 = Migration(version: 9, sql: """
    ALTER TABLE work ADD COLUMN circle_name_override TEXT;
    ALTER TABLE work ADD COLUMN seiyuu_names_override TEXT;
    ALTER TABLE work ADD COLUMN cover_asset_path TEXT;
    ALTER TABLE track ADD COLUMN asset_relative_path TEXT;
    CREATE UNIQUE INDEX idx_track_asset ON track(asset_relative_path)
        WHERE asset_relative_path IS NOT NULL;
    """)
}

extension Schema {
    /// v2：曲目类型（本編 / 特典 / 语音消息 / 闲聊 / 效果音）
    static let migration2 = Migration(version: 2, sql: """
    ALTER TABLE track ADD COLUMN category TEXT NOT NULL DEFAULT 'main';
    CREATE INDEX IF NOT EXISTS idx_track_category ON track(work_id, category);
    """)
}

extension Schema {
    /// v3：改成存**相对存储源的路径**。
    ///
    /// 原因：iOS 的 App 容器路径会变（重装、恢复备份都会换 UUID），
    /// 绝对路径存进数据库后就成了孤儿。改成相对路径 + 运行时解析。
    static let migration3 = Migration(version: 3, sql: """
    ALTER TABLE work  ADD COLUMN folder_rel TEXT;
    ALTER TABLE track ADD COLUMN file_rel   TEXT;

    CREATE UNIQUE INDEX IF NOT EXISTS idx_work_unique_rel ON work(source_id, folder_rel);
    CREATE INDEX IF NOT EXISTS idx_track_rel ON track(file_rel);
    """)
}

extension Schema {
    /// v4：允许用户手动调整分类与顺序
    ///
    /// - `category_override`：用户手动指定后，优先于自动识别结果
    /// - `sort_order`：手动排序（重扫时按文件路径保留）
    /// - `work.custom_categories`：作品自定义分组（JSON 数组，如 [{"key":"custom_1","title":"本篇"}]）
    static let migration4 = Migration(version: 4, sql: """
    ALTER TABLE track ADD COLUMN category_override TEXT;
    ALTER TABLE track ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE work  ADD COLUMN custom_categories TEXT;
    """)
}

extension Schema {
    /// v5：记住每个存储源导入时用的"分组模式"。
    ///
    /// 自动判断在真实目录上会猜错（比如一个特典目录里同时有 `wav/` 和 `SEあり/`，
    /// 会被拆成两个作品）。记住用户的选择，重新扫描时就用同一套规则。
    static let migration5 = Migration(version: 5, sql: """
    ALTER TABLE source ADD COLUMN grouping TEXT NOT NULL DEFAULT 'automatic';
    """)
}

extension Schema {
    /// v6：字幕。三层结构 —— 字幕轨 → 版本 → 条目。
    ///
    /// 为什么分三层：
    /// - 一个曲目可能有多条字幕轨（外挂原文、外挂译文、AI 生成、音频内嵌）
    /// - 每条轨可能有多个版本（AI 原始版、手工修正版…），原版永远保留
    /// - 条目挂在版本上，改坏能回滚
    static let migration6 = Migration(version: 6, sql: """
    CREATE TABLE IF NOT EXISTS subtitle_track (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        track_id   INTEGER NOT NULL REFERENCES track(id) ON DELETE CASCADE,
        kind       TEXT    NOT NULL DEFAULT 'sidecar',
        language   TEXT,
        label      TEXT,
        is_active  INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_subtitle_track ON subtitle_track(track_id);

    CREATE TABLE IF NOT EXISTS subtitle_version (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        subtitle_track_id INTEGER NOT NULL REFERENCES subtitle_track(id) ON DELETE CASCADE,
        version_no        INTEGER NOT NULL DEFAULT 1,
        note              TEXT,
        is_baseline       INTEGER NOT NULL DEFAULT 0,
        cue_count         INTEGER NOT NULL DEFAULT 0,
        created_at        INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_subtitle_version ON subtitle_version(subtitle_track_id);

    CREATE TABLE IF NOT EXISTS subtitle_cue (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        version_id      INTEGER NOT NULL REFERENCES subtitle_version(id) ON DELETE CASCADE,
        cue_index       INTEGER NOT NULL,
        start_ms        INTEGER NOT NULL,
        end_ms          INTEGER NOT NULL,
        source_text     TEXT    NOT NULL,
        translated_text TEXT,
        speaker         TEXT,
        status          TEXT    NOT NULL DEFAULT 'ok'
    );
    CREATE INDEX IF NOT EXISTS idx_subtitle_cue ON subtitle_cue(version_id, start_ms);
    """)
}

extension Schema {
    static let migration7 = Migration(version: 7, sql: """
    CREATE TABLE playlist_entry (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        track_id       INTEGER REFERENCES track(id) ON DELETE SET NULL,
        title          TEXT NOT NULL,
        work_title     TEXT NOT NULL,
        start_ms       INTEGER,
        end_ms         INTEGER,
        clip_filename  TEXT UNIQUE,
        created_at     INTEGER NOT NULL,
        CHECK ((clip_filename IS NULL AND start_ms IS NULL AND end_ms IS NULL) OR
               (clip_filename IS NOT NULL AND start_ms IS NOT NULL AND end_ms IS NOT NULL
                AND start_ms >= 0 AND end_ms > start_ms))
    );
    CREATE UNIQUE INDEX playlist_whole_track ON playlist_entry(track_id) WHERE clip_filename IS NULL;
    CREATE UNIQUE INDEX playlist_clip_range ON playlist_entry(track_id, start_ms, end_ms) WHERE clip_filename IS NOT NULL;
    """)
}

extension Schema {
    static let migration8 = Migration(version: 8, sql: """
    CREATE TABLE playlist_group (
        id       INTEGER PRIMARY KEY AUTOINCREMENT,
        name     TEXT NOT NULL,
        is_clips INTEGER NOT NULL CHECK (is_clips IN (0, 1)),
        UNIQUE (is_clips, name)
    );
    INSERT INTO playlist_group (id, name, is_clips) VALUES (1, '默认整曲', 0), (2, '默认摘选', 1);

    ALTER TABLE playlist_entry RENAME TO playlist_entry_v7;
    CREATE TABLE playlist_entry (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id       INTEGER NOT NULL REFERENCES playlist_group(id),
        track_id       INTEGER REFERENCES track(id) ON DELETE SET NULL,
        title          TEXT NOT NULL,
        work_title     TEXT NOT NULL,
        start_ms       INTEGER,
        end_ms         INTEGER,
        clip_filename  TEXT UNIQUE,
        merged_ms      INTEGER,
        cover_work_id  INTEGER REFERENCES work(id) ON DELETE SET NULL,
        created_at     INTEGER NOT NULL,
        CHECK (
            (clip_filename IS NULL AND start_ms IS NULL AND end_ms IS NULL AND merged_ms IS NULL)
         OR (clip_filename IS NOT NULL AND start_ms IS NOT NULL AND end_ms IS NOT NULL
             AND start_ms >= 0 AND end_ms > start_ms AND merged_ms IS NULL)
         OR (clip_filename IS NOT NULL AND track_id IS NULL AND start_ms IS NULL AND end_ms IS NULL
             AND merged_ms IS NOT NULL AND merged_ms > 0)
        )
    );
    INSERT INTO playlist_entry (id, group_id, track_id, title, work_title, start_ms, end_ms, clip_filename, created_at)
    SELECT id, CASE WHEN clip_filename IS NULL THEN 1 ELSE 2 END,
           track_id, title, work_title, start_ms, end_ms, clip_filename, created_at FROM playlist_entry_v7;
    DROP TABLE playlist_entry_v7;
    CREATE UNIQUE INDEX playlist_whole_track ON playlist_entry(group_id, track_id) WHERE clip_filename IS NULL;
    CREATE UNIQUE INDEX playlist_clip_range ON playlist_entry(group_id, track_id, start_ms, end_ms)
        WHERE clip_filename IS NOT NULL;
    """)
}


extension Schema {
    static let migration11 = Migration(version: 11, sql: """
    ALTER TABLE playlist_group ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0;
    UPDATE playlist_group SET sort_order = id;
    CREATE TABLE favorite_group (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        sort_order INTEGER NOT NULL DEFAULT 0
    );
    INSERT INTO favorite_group (id, name) VALUES (1, '默认收藏');
    CREATE TABLE favorite_membership (
        work_id INTEGER NOT NULL REFERENCES work(id) ON DELETE CASCADE,
        group_id INTEGER NOT NULL REFERENCES favorite_group(id) ON DELETE CASCADE,
        PRIMARY KEY (work_id, group_id)
    );
    INSERT INTO favorite_membership (work_id, group_id) SELECT id, 1 FROM work WHERE favorite = 1;
    CREATE TRIGGER favorite_on AFTER UPDATE OF favorite ON work
        WHEN NEW.favorite = 1 AND NOT EXISTS (SELECT 1 FROM favorite_membership WHERE work_id = NEW.id)
        BEGIN INSERT INTO favorite_membership (work_id, group_id) VALUES (NEW.id, 1); END;
    CREATE TRIGGER favorite_off AFTER UPDATE OF favorite ON work WHEN NEW.favorite = 0
        BEGIN DELETE FROM favorite_membership WHERE work_id = NEW.id; END;

    -- 移除分类时，同范围的两个独立音频都要保留。新增摘选仍由单条写入语句去重。
    DROP INDEX playlist_clip_range;
    CREATE INDEX playlist_clip_range ON playlist_entry(group_id, track_id, start_ms, end_ms)
        WHERE clip_filename IS NOT NULL;
    """)
}

extension Schema {
    static let migration13 = Migration(version: 13, sql: """
    ALTER TABLE work ADD COLUMN rj_code_override TEXT;
    ALTER TABLE work ADD COLUMN category_order TEXT;
    CREATE TABLE work_attachment (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        work_id INTEGER NOT NULL REFERENCES work(id) ON DELETE CASCADE,
        relative_path TEXT NOT NULL,
        kind TEXT NOT NULL,
        byte_count INTEGER NOT NULL,
        asset_relative_path TEXT UNIQUE,
        category_key TEXT NOT NULL DEFAULT 'attachments',
        sort_order INTEGER NOT NULL DEFAULT 0
    );
    CREATE UNIQUE INDEX attachment_source_path ON work_attachment(work_id, relative_path)
        WHERE asset_relative_path IS NULL;
    CREATE TABLE excluded_work_file (
        work_id INTEGER NOT NULL REFERENCES work(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        PRIMARY KEY(work_id, kind, relative_path)
    );
    CREATE TABLE excluded_source_work (
        source_id INTEGER NOT NULL REFERENCES source(id) ON DELETE CASCADE,
        folder_rel TEXT NOT NULL,
        PRIMARY KEY(source_id, folder_rel)
    );
    """)

    /// 每部作品在本地一小时内只占一行。删除原作品后仍保留曾听过的时长和名称。
    static let migration14 = Migration(version: 14, sql: """
    CREATE TABLE play_statistic (
        date_key TEXT NOT NULL,
        hour_slot INTEGER NOT NULL CHECK (hour_slot BETWEEN 0 AND 23),
        work_id INTEGER NOT NULL CHECK (work_id >= 0),
        seconds INTEGER NOT NULL CHECK (seconds > 0),
        title TEXT,
        circle_name TEXT,
        seiyuu_names TEXT,
        scanned_seiyuu TEXT,
        PRIMARY KEY (date_key, hour_slot, work_id)
    );
    CREATE INDEX play_statistic_work ON play_statistic(work_id);
    CREATE TRIGGER preserve_listening_metadata BEFORE DELETE ON work BEGIN
        UPDATE play_statistic
        SET title = COALESCE(OLD.title_override, OLD.title),
            circle_name = COALESCE(OLD.circle_name_override, OLD.circle_name),
            seiyuu_names = OLD.seiyuu_names_override, scanned_seiyuu = OLD.seiyuu_name
        WHERE work_id = OLD.id;
    END;
    """)

    static let migration15 = Migration(version: 15, sql: """
    CREATE TABLE play_history (
        session_id TEXT PRIMARY KEY NOT NULL,
        started_at INTEGER NOT NULL,
        start_date_key TEXT NOT NULL,
        start_time_zone_id TEXT NOT NULL,
        work_id INTEGER NOT NULL CHECK (work_id >= 0),
        track_id INTEGER NOT NULL,
        work_title TEXT NOT NULL,
        track_title TEXT NOT NULL,
        is_saved_clip INTEGER NOT NULL CHECK (is_saved_clip IN (0, 1)),
        seconds INTEGER NOT NULL CHECK (seconds > 0)
    );
    CREATE INDEX play_history_recent ON play_history(started_at DESC, session_id);
    CREATE INDEX play_history_period ON play_history(start_date_key, started_at DESC);
    CREATE TRIGGER count_listening_session AFTER INSERT ON play_history WHEN NEW.work_id > 0 BEGIN
        UPDATE work SET play_count = play_count + 1 WHERE id = NEW.work_id;
    END;
    """)
}
