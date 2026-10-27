import Foundation
import SQLite3
import Testing
@testable import PasteMemo

@Suite("StorageCleaner.compactStore")
struct StorageCompactTests {
    @Test("A search index emptied by deletes shrinks back, and so does the file")
    func shrinksSearchIndexAfterDeletes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("compact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("PasteMemo.store").path

        let db = try #require(SQLiteConnection(path: path, readOnly: false, create: true))
        #expect(db.execute("PRAGMA auto_vacuum = INCREMENTAL"))
        #expect(db.execute("PRAGMA journal_mode = WAL"))
        // Same shape as the app's table (PasteMemoApp.ensureFTS).
        #expect(db.execute("""
            CREATE VIRTUAL TABLE clip_fts USING fts5(itemID UNINDEXED, content, displayTitle, linkTitle, ocrText, tokenize='trigram')
            """))
        _ = db.performInTransaction {
            for index in 0..<4000 {
                let text = "第 \(index) 条记录 " + String(repeating: "abcdefghij\(index % 97) ", count: 20)
                guard db.run("INSERT INTO clip_fts(itemID, content) VALUES (?, ?)", params: ["id\(index)", text]) else { return false }
            }
            return true
        }
        #expect(db.execute("DELETE FROM clip_fts WHERE itemID != 'id0'"))
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        let pagesBefore = db.queryInt("PRAGMA page_count")
        db.close()

        StorageCleaner.compactStore(at: path)

        let after = try #require(SQLiteConnection(path: path, readOnly: true))
        defer { after.close() }
        let pagesAfter = after.queryInt("PRAGMA page_count")
        #expect(pagesAfter * 5 < pagesBefore, "before \(pagesBefore) pages, after \(pagesAfter)")
        let matches = after.queryInt("SELECT count(*) FROM clip_fts WHERE clip_fts MATCH 'abcdefghij'")
        #expect(matches == 1)
        let wal = (try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? NSNumber)?.intValue ?? 0
        #expect(wal == 0)
    }
}
