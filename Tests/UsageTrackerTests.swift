import Foundation
import Testing
@testable import PasteMemo

@Suite("Usage ping dedupe")
@MainActor
struct UsageTrackerTests {
    /// 北京时间 2026-11-06 17:42 = UTC 09:42
    private let now = ISO8601DateFormatter().date(from: "2026-11-06T09:42:00Z")!
    /// 北京时间当天 10:32 = UTC 02:32
    private let earlierToday = ISO8601DateFormatter().date(from: "2026-11-06T02:32:53Z")!
    /// 北京时间 11-05 23:30 = UTC 15:30
    private let yesterdayLate = ISO8601DateFormatter().date(from: "2026-11-05T15:30:00Z")!

    @Test("never pinged → ping")
    func firstPing() {
        #expect(UsageTracker.shouldPing(lastPing: nil, lastVersion: nil, version: "1.18.0", now: now))
    }

    @Test("already pinged today with this version → skip")
    func sameDaySameVersion() {
        #expect(!UsageTracker.shouldPing(lastPing: earlierToday, lastVersion: "1.18.0", version: "1.18.0", now: now))
    }

    @Test("pinged today with an older version, then upgraded → ping again")
    func sameDayUpgrade() {
        #expect(UsageTracker.shouldPing(lastPing: earlierToday, lastVersion: "1.17.0", version: "1.18.0", now: now))
    }

    @Test("today's ping came from a client that didn't record its version → it was another version, ping")
    func sameDayLegacyClient() {
        #expect(UsageTracker.shouldPing(lastPing: earlierToday, lastVersion: nil, version: "1.18.0", now: now))
    }

    @Test("last ping was yesterday in Asia/Shanghai → ping, even with the same version")
    func newDay() {
        #expect(UsageTracker.shouldPing(lastPing: yesterdayLate, lastVersion: "1.18.0", version: "1.18.0", now: now))
    }
}
