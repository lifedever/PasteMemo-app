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
