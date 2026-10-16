import Foundation
import SwiftData
import Testing
@testable import PasteMemo

/// Conditions added on top of the content / source-app ones: paste target, size,
/// clip state, time, and negation.
@Suite("Rule conditions: target app, size, state, time, not")
struct RuleConditionContextTests {

    private func input(_ content: String = "hello", type: ClipContentType = .text, target: String? = nil,
                       sensitive: Bool = false, pinned: Bool = false, group: String? = nil,
                       at date: Date = Date()) -> ConditionInput {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return ConditionInput(content: content, contentType: type, sourceApp: nil, targetApp: target,
                              isSensitive: sensitive, isPinned: pinned, groupName: group,
                              now: date, calendar: calendar)
    }

    /// 2026-10-16 is a Friday (weekday 6).
    private func shanghai(_ hour: Int, _ minute: Int, day: Int = 16) -> Date {
        var parts = DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)
        parts.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return Calendar(identifier: .gregorian).date(from: parts)!
    }

    @Test("targetApp: listed app matches, unknown target never does, empty list always does")
    func targetApp() {
        let xcode = RuleCondition.targetApp(bundleIDs: ["com.apple.dt.Xcode"])
        #expect(xcode.matches(input(target: "com.apple.dt.Xcode")))
        #expect(!xcode.matches(input(target: "com.tencent.xinWeChat")))
        #expect(!xcode.matches(input(target: nil)))
        #expect(RuleCondition.targetApp(bundleIDs: []).matches(input(target: nil)))
    }

    @Test("contentLength and lineCount bounds; nil = unbounded")
    func sizeBounds() {
        #expect(RuleCondition.contentLength(min: 3, max: 5).matches(input("abcd")))
        #expect(!RuleCondition.contentLength(min: 5, max: nil).matches(input("abcd")))
        #expect(!RuleCondition.contentLength(min: nil, max: 3).matches(input("abcd")))
        #expect(RuleCondition.contentLength(min: nil, max: nil).matches(input("")))
        #expect(RuleCondition.contentLength(min: 2, max: 2).matches(input("你好")))

        #expect(RuleCondition.lineCount(of: "a\nb\nc\n") == 3)
        #expect(RuleCondition.lineCount(of: "") == 0)
        #expect(RuleCondition.lineCount(min: 2, max: nil).matches(input("a\nb")))
        #expect(!RuleCondition.lineCount(min: 2, max: nil).matches(input("single line")))
        #expect(RuleCondition.lineCount(min: nil, max: 1).matches(input("single line")))
    }

    @Test("clip state: sensitive, pinned, group (empty name = any group)")
    func clipState() {
        #expect(RuleCondition.isSensitive.matches(input(sensitive: true)))
        #expect(!RuleCondition.isSensitive.matches(input()))
        #expect(RuleCondition.isPinned.matches(input(pinned: true)))
        #expect(RuleCondition.inGroup(name: "工作").matches(input(group: "工作")))
        #expect(!RuleCondition.inGroup(name: "工作").matches(input(group: "生活")))
        #expect(RuleCondition.inGroup(name: "").matches(input(group: "生活")))
        #expect(!RuleCondition.inGroup(name: "").matches(input(group: nil)))
    }

    @Test("timeOfDay: [start, end), wraps past midnight, equal bounds = all day")
    func timeOfDay() {
        let work = RuleCondition.timeOfDay(startMinute: 9 * 60, endMinute: 18 * 60)
        #expect(work.matches(input(at: shanghai(9, 0))))
        #expect(work.matches(input(at: shanghai(17, 59))))
        #expect(!work.matches(input(at: shanghai(18, 0))))
        #expect(!work.matches(input(at: shanghai(8, 59))))

        let night = RuleCondition.timeOfDay(startMinute: 22 * 60, endMinute: 7 * 60)
        #expect(night.matches(input(at: shanghai(23, 30))))
        #expect(night.matches(input(at: shanghai(6, 0))))
        #expect(!night.matches(input(at: shanghai(12, 0))))

        #expect(RuleCondition.timeOfDay(startMinute: 600, endMinute: 600).matches(input(at: shanghai(3, 0))))
    }

    @Test("weekday uses Calendar numbering (1 = Sunday); empty = every day")
    func weekday() {
        let weekdays = RuleCondition.weekday(days: [2, 3, 4, 5, 6])
        #expect(weekdays.matches(input(at: shanghai(12, 0, day: 16))))   // Friday
        #expect(!weekdays.matches(input(at: shanghai(12, 0, day: 18))))  // Sunday
        #expect(RuleCondition.weekday(days: []).matches(input()))
    }

    @Test("not inverts; unwrappedNegation peels any depth")
    func negation() {
        let notXcode = RuleCondition.not(.targetApp(bundleIDs: ["com.apple.dt.Xcode"]))
        #expect(notXcode.matches(input(target: "com.tencent.xinWeChat")))
        #expect(notXcode.matches(input(target: nil)))
        #expect(!notXcode.matches(input(target: "com.apple.dt.Xcode")))

        #expect(notXcode.unwrappedNegation.negated)
        #expect(RuleCondition.not(.not(.anyText)).unwrappedNegation == (base: .anyText, negated: false))
    }

    @Test("clip-context conditions are flagged for the editor preview, negated ones too")
    func needsClipContext() {
        #expect(RuleCondition.isPinned.needsClipContext)
        #expect(RuleCondition.not(.sourceApp(bundleIDs: ["x"])).needsClipContext)
        #expect(!RuleCondition.contentLength(min: 1, max: nil).needsClipContext)
        #expect(!RuleCondition.timeOfDay(startMinute: 0, endMinute: 60).needsClipContext)
    }

    @Test("every new condition survives an encode / decode round trip")
    func codable() throws {
        let conditions: [RuleCondition] = [
            .targetApp(bundleIDs: ["com.apple.dt.Xcode"]),
            .contentLength(min: 10, max: nil), .lineCount(min: nil, max: 3),
            .isSensitive, .isPinned, .inGroup(name: "工作"),
            .timeOfDay(startMinute: 540, endMinute: 1080), .weekday(days: [2, 6]),
            .not(.containsText(text: "密码")), .not(.not(.anyText)),
        ]
        let decoded = try JSONDecoder().decode([RuleCondition].self, from: JSONEncoder().encode(conditions))
        #expect(decoded == conditions)
    }

    @Test("matches(item:) passes the paste target and clip state through")
    @MainActor
    func ruleMatchesItem() {
        let rule = AutomationRule(name: "t", conditions: [.targetApp(bundleIDs: ["com.apple.dt.Xcode"]), .isPinned],
                                  actions: [.toCamelCase])
        let pinned = ClipItem(content: "user_name", contentType: .text, isPinned: true)
        let loose = ClipItem(content: "user_name", contentType: .text)
        #expect(rule.matches(item: pinned, targetAppBundleID: "com.apple.dt.Xcode"))
        #expect(!rule.matches(item: pinned, targetAppBundleID: nil))
        #expect(!rule.matches(item: loose, targetAppBundleID: "com.apple.dt.Xcode"))
    }

    @Test("capture: a later rule sees the pin an earlier rule set, and the capture-time sensitive flag")
    @MainActor
    func captureCarriesState() throws {
        let schema = Schema([ClipItem.self, SmartGroup.self, AutomationRule.self])
        let context = ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)))
        UserDefaults.standard.set(true, forKey: "automationEnabled")
        let pinIt = AutomationRule(name: "pin", sortOrder: 0, conditions: [.anyText], actions: [.pin])
        let tagPinned = AutomationRule(name: "tag", sortOrder: 1, conditions: [.isPinned], actions: [.addSuffix(text: " #p")])
        let hideSecret = AutomationRule(name: "secret", sortOrder: 2, conditions: [.isSensitive], actions: [.addPrefix(text: "!")])
        context.insert(pinIt); context.insert(tagPinned); context.insert(hideSecret)
        try context.save()

        let plain = AutomationEngine.shared.process(content: "hi", contentType: .text, sourceApp: nil, context: context)
        guard case .applied(let content, _, _, _, _) = plain else {
            Issue.record("expected .applied, got \(plain)")
            return
        }
        #expect(content == "hi #p")

        let secret = AutomationEngine.shared.process(content: "hi", contentType: .text, sourceApp: nil, isSensitive: true, context: context)
        guard case .applied(let secretContent, _, _, _, _) = secret else {
            Issue.record("expected .applied, got \(secret)")
            return
        }
        #expect(secretContent == "!hi #p")
    }
}
