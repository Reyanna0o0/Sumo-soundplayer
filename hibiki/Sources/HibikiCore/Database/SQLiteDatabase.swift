import Foundation
import SQLite3

/// 轻量 SQLite 封装。
///
/// 为什么自己写而不是用 GRDB：
/// 1. 系统自带 SQLite3，**零依赖** —— 内核能在 macOS 上直接跑测试，iOS 上也不用引入包
/// 2. 我们的查询很集中（十几张表、几十条语句），不需要完整 ORM
/// 3. 依赖越少，后面接 sherpa-onnx 之类的重型库时越不容易出冲突
///
/// **并发约定**：一个 `SQLiteDatabase` 实例只能在同一条串行队列上使用。
/// 需要并发时开多个连接（SQLite 自身支持），或在外层加串行队列。
public final class SQLiteDatabase {

    public enum Error: Swift.Error, LocalizedError, Equatable {
        case openFailed(code: Int32, message: String)
        case prepareFailed(sql: String, message: String)
        case stepFailed(sql: String, message: String)
        case bindFailed(index: Int32, message: String)
        case migrationFailed(version: Int, message: String)
        case closed

        public var errorDescription: String? {
            switch self {
            case .openFailed(let code, let message):
                return InterfaceLocalization.text("打开数据库失败（\(code)）：\(message)")
            case .prepareFailed(let sql, let message):
                return InterfaceLocalization.text("SQL 预编译失败：\(message)\n语句：\(sql)")
            case .stepFailed(let sql, let message):
                return InterfaceLocalization.text("SQL 执行失败：\(message)\n语句：\(sql)")
            case .bindFailed(let index, let message):
                return InterfaceLocalization.text("参数绑定失败（第 \(index) 个）：\(message)")
            case .migrationFailed(let version, let message):
                return InterfaceLocalization.text("数据库迁移失败（版本 \(version)）：\(message)")
            case .closed:
                return InterfaceLocalization.text("数据库连接已关闭")
            }
        }
    }

    private var handle: OpaquePointer?
    private let path: String
    /// 预编译语句缓存：同一条 SQL 只 prepare 一次
    private var statementCache: [String: OpaquePointer] = [:]
    /// 递归事务深度，用于支持嵌套调用
    private var transactionDepth = 0

    /// 打开数据库。`path` 传 `":memory:"` 得到内存库（用于测试）。
    public init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? InterfaceLocalization.text("未知错误")
            if let db { sqlite3_close(db) }
            throw Error.openFailed(code: rc, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 3_000)
        // SQL filtering/sorting and TrackRecord.displayTitle use the same filename fallback.
        let functionResult = sqlite3_create_function_v2(db, "filename_stem", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            nil, { context, _, arguments in
                guard let value = arguments?[0], let bytes = sqlite3_value_text(value) else {
                    sqlite3_result_null(context)
                    return
                }
                let name = String(cString: bytes) as NSString
                sqlite3_result_text(context, name.deletingPathExtension, -1, SQLITE_TRANSIENT)
            }, nil, nil, nil)
        guard functionResult == SQLITE_OK else {
            throw Error.openFailed(code: functionResult, message: String(cString: sqlite3_errmsg(db)))
        }
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
    }

    deinit {
        for (_, stmt) in statementCache { sqlite3_finalize(stmt) }
        statementCache.removeAll()
        if let handle { sqlite3_close(handle) }
    }

    public static func inMemory() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: ":memory:")
    }

    public var databasePath: String { path }

    public func close() {
        for (_, stmt) in statementCache { sqlite3_finalize(stmt) }
        statementCache.removeAll()
        if let handle {
            sqlite3_close(handle)
            self.handle = nil
        }
    }

    private var db: OpaquePointer {
        guard let handle else { fatalError("数据库已关闭") }
        return handle
    }

    // MARK: - 执行

    /// 执行多条 SQL（不含参数绑定）。用于建表、迁移。
    public func executeScript(_ sql: String) throws {
        guard handle != nil else { throw Error.closed }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if rc != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? InterfaceLocalization.text("未知错误")
            sqlite3_free(errorPointer)
            throw Error.stepFailed(sql: sql, message: message)
        }
    }

    /// 执行单条带参数的 SQL（INSERT / UPDATE / DELETE / PRAGMA）
    @discardableResult
    public func execute(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        let stmt = try preparedStatement(sql)
        defer { resetStatement(stmt) }
        try bind(stmt, params, sql: sql)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw Error.stepFailed(sql: sql, message: lastErrorMessage)
        }
        return Int(sqlite3_changes(db))
    }

    /// 查询
    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        let stmt = try preparedStatement(sql)
        defer { resetStatement(stmt) }
        try bind(stmt, params, sql: sql)

        var rows: [SQLRow] = []
        var columnNames: [String] = []

        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                // SQLite may reprepare a cached SELECT after a migration during
                // the first step. Only then are its current columns available.
                if columnNames.isEmpty {
                    let count = sqlite3_column_count(stmt)
                    columnNames.reserveCapacity(Int(count))
                    for i in 0..<count {
                        columnNames.append(String(cString: sqlite3_column_name(stmt, i)))
                    }
                }
                var values: [String: SQLValue] = [:]
                for (index, name) in columnNames.enumerated() {
                    values[name] = readValue(stmt, index: Int32(index))
                }
                rows.append(SQLRow(values))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw Error.stepFailed(sql: sql, message: lastErrorMessage)
            }
        }
        return rows
    }

    /// 查询单个整数（COUNT / MAX 等）
    public func queryInt(_ sql: String, _ params: [SQLValue] = []) throws -> Int? {
        guard let row = try query(sql, params).first else { return nil }
        guard let first = row.values.values.first else { return nil }
        return first.intValue.map { Int($0) }
    }

    /// 最后插入的 rowid
    public var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(db)
    }

    // MARK: - 事务

    /// 在事务里执行。出错自动回滚；嵌套调用会共用外层事务。
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }

        try execute("BEGIN IMMEDIATE")
        transactionDepth = 1
        do {
            let result = try body()
            try execute("COMMIT")
            transactionDepth = 0
            return result
        } catch {
            try? execute("ROLLBACK")
            transactionDepth = 0
            throw error
        }
    }

    // MARK: - 迁移

    /// 读 `PRAGMA user_version`
    public var userVersion: Int {
        (try? queryInt("PRAGMA user_version")) ?? 0
    }

    /// 按顺序应用迁移。已经应用过的版本会跳过。
    @discardableResult
    public func migrate(_ migrations: [Migration]) throws -> Int {
        let current = userVersion
        var applied = 0
        for migration in migrations.sorted(by: { $0.version < $1.version }) where migration.version > current {
            do {
                try transaction {
                    try executeScript(migration.sql)
                    try execute("PRAGMA user_version = \(migration.version)")
                }
                applied += 1
            } catch {
                throw Error.migrationFailed(version: migration.version, message: "\(error)")
            }
        }
        return applied
    }

    // MARK: - 内部

    private var lastErrorMessage: String {
        guard let handle else { return InterfaceLocalization.text("连接已关闭") }
        return String(cString: sqlite3_errmsg(handle))
    }

    private func preparedStatement(_ sql: String) throws -> OpaquePointer {
        guard handle != nil else { throw Error.closed }
        if let cached = statementCache[sql] { return cached }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw Error.prepareFailed(sql: sql, message: lastErrorMessage)
        }
        statementCache[sql] = stmt
        return stmt
    }

    private func resetStatement(_ stmt: OpaquePointer) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    private func bind(_ stmt: OpaquePointer, _ params: [SQLValue], sql: String) throws {
        // SQLite 参数下标从 1 开始
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(stmt, index)
            case .integer(let v):
                rc = sqlite3_bind_int64(stmt, index, v)
            case .real(let v):
                rc = sqlite3_bind_double(stmt, index, v)
            case .text(let s):
                rc = sqlite3_bind_text(stmt, index, s, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                if data.isEmpty {
                    rc = sqlite3_bind_zeroblob(stmt, index, 0)
                } else {
                    rc = data.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(
                            stmt, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT
                        )
                    }
                }
            }
            if rc != SQLITE_OK {
                throw Error.bindFailed(index: index, message: lastErrorMessage)
            }
        }
    }

    private func readValue(_ stmt: OpaquePointer, index: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(stmt, index))
        case SQLITE_TEXT:
            guard let cString = sqlite3_column_text(stmt, index) else { return .null }
            return .text(String(cString: cString))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(stmt, index))
            guard count > 0, let bytes = sqlite3_column_blob(stmt, index) else {
                return .blob(Data())
            }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }
}

/// SQLite 的 TRANSIENT 析构标记：告诉 SQLite 复制一份数据，别引用我们的内存。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 一次数据库迁移
public struct Migration: Sendable {
    public let version: Int
    public let sql: String

    public init(version: Int, sql: String) {
        self.version = version
        self.sql = sql
    }
}
