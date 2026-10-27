import Foundation
import Testing
@testable import PasteMemo

@Suite("StorageQuery")
struct StorageQueryTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 18))! }

    private func day(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func record(
        _ id: String, source: String?, _ category: StorageCategory = .text, at date: Date,
        bytes: Int64 = 10, protected: Bool = false
    ) -> StorageRecord {
        StorageRecord(
            id: id, sourceName: source, category: category, createdAt: date, isProtected: protected,
            originalBytes: 0, previewBytes: bytes, richTextBytes: 0, textBytes: 0, originalPath: nil
        )
    }

    @Test("「N 个月前」is strictly older than N calendar months")
    func olderThan() {
        let filter = StorageTimeFilter.olderThan(months: 3)
        #expect(filter.contains(day(7, 25), now: now, calendar: calendar))
        #expect(!filter.contains(day(7, 26, hour: 19), now: now, calendar: calendar))
        #expect(!filter.contains(day(10, 1), now: now, calendar: calendar))
    }

    @Test("Custom range includes both whole days, in either order")
    func range() {
        let filter = StorageTimeFilter.range(from: day(9, 10), to: day(9, 1))
        #expect(filter.contains(day(9, 1, hour: 0), now: now, calendar: calendar))
        #expect(filter.contains(day(9, 10, hour: 23), now: now, calendar: calendar))
        #expect(!filter.contains(day(8, 31, hour: 23), now: now, calendar: calendar))
        #expect(!filter.contains(day(9, 11, hour: 0), now: now, calendar: calendar))
    }

    @Test("Content types fold into the storage categories")
    func categories() {
        #expect(StorageCategory(contentTypeRaw: "image") == .image)
        #expect(StorageCategory(contentTypeRaw: "document") == .file)
        #expect(StorageCategory(contentTypeRaw: "archive") == .file)
        #expect(StorageCategory(contentTypeRaw: "phone") == .other)
        #expect(StorageCategory(contentTypeRaw: "no-such-type") == .other)
    }

    @Test("Protected clips never count as deletable; type and time filters combine")
    func deletable() {
        let records = [
            record("a", source: "微信", .image, at: day(5, 1)),
            record("b", source: "微信", .image, at: day(5, 1), protected: true),
            record("c", source: "微信", .text, at: day(5, 1)),
            record("d", source: "微信", .image, at: day(10, 20)),
        ]
        let filter = StorageFilter(time: .olderThan(months: 3), categories: [.image])
        #expect(StorageQuery.deletable(records, filter: filter, now: now, calendar: calendar).map(\.id) == ["a"])
        #expect(StorageQuery.deletable(records, filter: StorageFilter(), now: now, calendar: calendar).count == 3)
    }

    @Test("Sources sum count, bytes and latest time; the unknown source sorts last")
    func sources() {
        let records = [
            record("a", source: "微信", at: day(5, 1), bytes: 100),
            record("b", source: "微信", at: day(9, 1), bytes: 50),
            record("c", source: nil, at: day(10, 1), bytes: 500),
            record("d", source: "Chrome", at: day(6, 1), bytes: 150),
        ]
        let bySize = StorageQuery.sources(records)
        #expect(bySize.map(\.id) == ["", "Chrome", "微信"] || bySize.map(\.id) == ["", "微信", "Chrome"])
        #expect(bySize.first?.bytes == 500)
        let weChat = bySize.first { $0.sourceName == "微信" }
        #expect(weChat?.count == 2 && weChat?.bytes == 150 && weChat?.latest == day(9, 1))
        // Locale-aware name order (same as Finder); only the unknown source's place is fixed.
        let byName = StorageQuery.sources(records, sort: .name).map(\.id)
        #expect(byName.last == "" && Set(byName.dropLast()) == ["Chrome", "微信"])
        #expect(StorageQuery.sources(records, sort: .count).first?.id == "微信")
    }

    @Test("Category totals skip empty types, largest first")
    func categoryTotals() {
        let records = [
            record("a", source: nil, .image, at: day(5, 1), bytes: 300),
            record("b", source: nil, .text, at: day(5, 1), bytes: 10),
            record("c", source: nil, .text, at: day(5, 1), bytes: 10),
        ]
        let totals = StorageQuery.categoryTotals(records)
        #expect(totals.map(\.category) == [.image, .text])
        #expect(totals.last?.count == 2)
    }

    @Test("Grouping by type: one row per type with count, size and latest; menu order for names")
    func groupsByType() {
        let records = [
            record("a", source: "微信", .image, at: day(5, 1), bytes: 300),
            record("b", source: "Chrome", .image, at: day(9, 1), bytes: 100),
            record("c", source: "微信", .text, at: day(10, 1), bytes: 10),
            record("d", source: nil, .link, at: day(6, 1), bytes: 500),
        ]
        let bySize = StorageQuery.groups(records, by: .type)
        #expect(bySize.map(\.key) == [.category(.link), .category(.image), .category(.text)])
        let images = bySize[1]
        #expect(images.count == 2 && images.bytes == 400 && images.latest == day(9, 1))
        #expect(StorageQuery.groups(records, by: .type, sort: .name).map(\.key)
                == [.category(.image), .category(.text), .category(.link)])
        #expect(StorageQuery.groups(records, by: .type, sort: .latest).first?.key == .category(.text))
        #expect(StorageQuery.groups(records, by: .source).first?.key == .source(""))
    }

    @Test("A group key tells which records belong to it")
    func groupKeyMembership() {
        let unknown = record("x", source: nil, .code, at: day(5, 1))
        #expect(StorageGroupKey.source("").contains(unknown))
        #expect(!StorageGroupKey.source("微信").contains(unknown))
        #expect(StorageGroupKey.category(.code).contains(unknown))
        #expect(!StorageGroupKey.category(.text).contains(unknown))
    }

    @Test("Original-cache guard only accepts files directly inside the cache folder")
    func cacheGuard() {
        let dir = "/Users/me/Library/Application Support/com.lifedever.pastememo/Originals"
        #expect(StorageCleaner.isInside(dir + "/A.tiff", directory: dir))
        #expect(!StorageCleaner.isInside(dir + "/../PasteMemo.store", directory: dir))
        #expect(!StorageCleaner.isInside("/Users/me/Pictures/截图/shot.png", directory: dir))
        #expect(!StorageCleaner.isInside(dir + "/sub/A.tiff", directory: dir))
    }
}
