import CSQLite
import Foundation

public enum HanvonNoteCatalog {
    public struct Record: Sendable {
        public let key: String
        public let title: String
        public let type: Int64?
        public let protected: Bool
    }

    /// Only reads a local quiescent copy. Never opens the device database.
    public static func read(_ file: URL) throws -> [Record] {
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size <= 16 * 1024 * 1024 else {
            throw ToolboxError.unsupported("笔记索引不是受支持的本地数据库")
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw ToolboxError.message("无法读取笔记索引")
        }
        defer { sqlite3_close(db) }
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1024 * 1024)
        sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 64 * 1024)
        sqlite3_limit(db, SQLITE_LIMIT_COLUMN, 256)
        // Apple's system SQLite omits extension loading; the read authorizer below
        // also denies function calls and all writes from catalog queries.
        sqlite3_busy_timeout(db, 500)
        let deadline = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        deadline.initialize(to: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        defer { deadline.deinitialize(count: 1); deadline.deallocate() }
        sqlite3_progress_handler(db, 500, { pointer in
            guard let pointer else { return 1 }
            return DispatchTime.now().uptimeNanoseconds > pointer.assumingMemoryBound(to: UInt64.self).pointee ? 1 : 0
        }, deadline)
        try execute(db, "PRAGMA query_only=ON")
        try execute(db, "PRAGMA trusted_schema=OFF")
        let check = try statement(db, "PRAGMA quick_check")
        guard sqlite3_step(check) == SQLITE_ROW, string(check, 0) == "ok" else {
            sqlite3_finalize(check); throw ToolboxError.message("笔记索引完整性检查未通过")
        }
        sqlite3_finalize(check)
        let table = try statement(db, "SELECT type FROM sqlite_schema WHERE name='NoteList'")
        let ordinary = sqlite3_step(table) == SQLITE_ROW && string(table, 0) == "table"
        sqlite3_finalize(table)
        guard ordinary else { throw ToolboxError.unsupported("尚未适配此笔记索引结构") }
        let schema = try statement(db, "PRAGMA table_info('NoteList')")
        var columns = Set<String>()
        while sqlite3_step(schema) == SQLITE_ROW { columns.insert(string(schema, 1)) }
        sqlite3_finalize(schema)
        guard columns.contains("name"), columns.contains("nameUser") else {
            throw ToolboxError.unsupported("笔记索引缺少已知的标题与目录字段")
        }
        // Only allow reads of the ordinary NoteList table after schema validation.
        sqlite3_set_authorizer(db, { _, action, name, _, _, _ in
            if action == SQLITE_SELECT { return SQLITE_OK }
            if action == SQLITE_READ, let name, String(cString: name) == "NoteList" { return SQLITE_OK }
            return SQLITE_DENY
        }, nil)
        let sql = "SELECT name,nameUser," + (columns.contains("noteType") ? "noteType" : "NULL")
            + "," + (columns.contains("hasPsd") ? "hasPsd" : "NULL") + " FROM NoteList LIMIT 50001"
        let query = try statement(db, sql)
        defer { sqlite3_finalize(query) }
        var result: [Record] = []
        var keys = Set<String>()
        while true {
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw ToolboxError.message("笔记索引读取失败或超时") }
            guard result.count < 50_000 else { throw ToolboxError.unsupported("笔记索引超过 50,000 条，请缩小来源") }
            let key = string(query, 0)
            guard key.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
                  keys.insert(key).inserted else { throw ToolboxError.invalidResponse("笔记目录标识无效或重复") }
            let title = string(query, 1)
            guard title.utf8.count <= 4096, !title.contains("\0") else {
                throw ToolboxError.invalidResponse("笔记标题字段无效")
            }
            // Missing/unknown protection flags do not authorize exporting protected data.
            let protected = sqlite3_column_type(query, 3) != SQLITE_INTEGER || sqlite3_column_int64(query, 3) != 0
            result.append(.init(key: key, title: title.isEmpty ? "未命名笔记" : title,
                                type: sqlite3_column_type(query, 2) == SQLITE_INTEGER ? sqlite3_column_int64(query, 2) : nil,
                                protected: protected))
        }
        return result
    }

    private static func statement(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ToolboxError.unsupported("无法解析此版本笔记索引")
        }
        return statement
    }
    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        let statement = try statement(db, sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ToolboxError.message("无法配置只读索引检查") }
    }
    private static func string(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }
}
