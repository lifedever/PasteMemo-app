import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite wrapper for indexes and FTS5. SwiftData handles all normal data operations.
final class SQLiteConnection {
    private var db: OpaquePointer?

    /// `create` makes the file if it's missing (tests); the app only ever opens SwiftData's store.
    init?(path: String, readOnly: Bool = false, create: Bool = false) {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0))
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
    }

    /// 返回是否成功。DDL 维护路径要看它：DROP 成功、CREATE 失败这种半截状态以前被
    /// 吞掉的返回值全盖住了。
    @discardableResult
    func execute(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// 最近一次失败的 SQLite 错误描述（写诊断日志用）。
    var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(db))
    }

    /// 撞锁时等待而不是立刻返回 SQLITE_BUSY。这条连接和 SwiftData 的连接共用同一个
    /// WAL 库，DDL 要写锁；默认 0 超时意味着对方正在写的那一瞬间我们的 DDL 直接失败。
    func setBusyTimeout(milliseconds: Int32) {
        sqlite3_busy_timeout(db, milliseconds)
    }

    /// 把一段语句包进 IMMEDIATE 事务：开事务即取写锁（配合 busy timeout 等待），
    /// body 返回 false 或 COMMIT 失败都整体 ROLLBACK。返回是否提交成功。
    func performInTransaction(_ body: () -> Bool) -> Bool {
        guard execute("BEGIN IMMEDIATE") else { return false }
        guard body(), execute("COMMIT") else {
            execute("ROLLBACK")
            return false
        }
        return true
    }

    /// 表里是否已有这一列（pragma_table_info 表值函数，SQLite ≥ 3.16）。
    func columnExists(table: String, column: String) -> Bool {
        !queryStrings(
            "SELECT name FROM pragma_table_info(?) WHERE name = ?",
            params: [table, column]
        ).isEmpty
    }

    private func bind(_ params: [Any], to stmt: OpaquePointer?) {
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case let s as String:
                sqlite3_bind_text(stmt, idx, (s as NSString).utf8String, -1, SQLITE_TRANSIENT)
            case let n as Int:
                sqlite3_bind_int64(stmt, idx, Int64(n))
            case let d as Double:
                sqlite3_bind_double(stmt, idx, d)
            default:
                sqlite3_bind_text(stmt, idx, ("\(param)" as NSString).utf8String, -1, SQLITE_TRANSIENT)
            }
        }
    }

    /// Query that returns string values from the first column of each row.
    func queryStrings(_ sql: String, params: [Any] = []) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        bind(params, to: stmt)

        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                results.append(String(cString: cStr))
            }
        }
        return results
    }

    func queryInt(_ sql: String, params: [Any] = []) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bind(params, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func queryIntRow(_ sql: String, params: [Any] = [], columnCount: Int) -> [Int] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return Array(repeating: 0, count: columnCount)
        }
        defer { sqlite3_finalize(stmt) }

        bind(params, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return Array(repeating: 0, count: columnCount)
        }

        return (0..<columnCount).map { index in
            Int(sqlite3_column_int64(stmt, Int32(index)))
        }
    }

    func queryStringIntPairs(_ sql: String, params: [Any] = []) -> [(String, Int)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        bind(params, to: stmt)

        var results: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let value = Int(sqlite3_column_int64(stmt, 1))
            results.append((key, value))
        }
        return results
    }

    func queryStringStringIntTuples(_ sql: String, params: [Any] = []) -> [(String, String, Int)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        bind(params, to: stmt)

        var results: [(String, String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let first = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let second = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let third = Int(sqlite3_column_int64(stmt, 2))
            results.append((first, second, third))
        }
        return results
    }

    func queryGroupRows(_ sql: String, params: [Any] = []) -> [(String, String, Int, Bool)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        bind(params, to: stmt)

        var results: [(String, String, Int, Bool)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let icon = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_int64(stmt, 2))
            let preservesItems = sqlite3_column_int64(stmt, 3) != 0
            results.append((name, icon, count, preservesItems))
        }
        return results
    }

    /// Rows of (rowid, text, blob). Used by SMSCodeWatcher to read Messages rows
    /// whose body may live either in `text` or in the `attributedBody` blob.
    func queryIntTextBlobRows(_ sql: String, params: [Any] = []) -> [(Int, String?, Data?)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        bind(params, to: stmt)

        var results: [(Int, String?, Data?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let text = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            var blob: Data?
            if sqlite3_column_type(stmt, 2) == SQLITE_BLOB,
               let bytes = sqlite3_column_blob(stmt, 2) {
                blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 2)))
            }
            results.append((id, text, blob))
        }
        return results
    }

    /// Runs one statement with bound parameters; returns whether it ran to completion.
    @discardableResult
    func run(_ sql: String, params: [Any]) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(params, to: stmt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Column accessors for `forEachRow`. Valid only inside the callback.
    struct Row {
        fileprivate let stmt: OpaquePointer?

        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(stmt, column) }
        func double(_ column: Int32) -> Double { sqlite3_column_double(stmt, column) }
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(stmt, column).map { String(cString: $0) }
        }
        func blob(_ column: Int32) -> Data? {
            guard sqlite3_column_type(stmt, column) == SQLITE_BLOB,
                  let bytes = sqlite3_column_blob(stmt, column) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
        }
    }

    /// Streams every result row through `body` without building an intermediate array.
    /// Returns false when the statement fails to prepare.
    @discardableResult
    func forEachRow(_ sql: String, params: [Any] = [], _ body: (Row) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(params, to: stmt)
        let row = Row(stmt: stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            body(row)
        }
        return true
    }

    /// Returns true if a table exists.
    func tableExists(_ name: String) -> Bool {
        !queryStrings(
            "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
            params: [name]
        ).isEmpty
    }

    func close() {
        sqlite3_close(db)
        db = nil
    }
}
