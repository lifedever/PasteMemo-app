import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite wrapper for indexes and FTS5. SwiftData handles all normal data operations.
final class SQLiteConnection {
    private var db: OpaquePointer?

    init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
    }

    func execute(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// Query that returns string values from the first column of each row.
    func queryStrings(_ sql: String, params: [Any] = []) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

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
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            if let s = param as? String {
                sqlite3_bind_text(stmt, idx, (s as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else if let d = param as? Double {
                sqlite3_bind_double(stmt, idx, d)
            }
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
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
