import Foundation
import Testing
@testable import PasteMemo

@Suite("RuleCondition Tests")
struct RuleConditionTests {

    // MARK: - contentType

    @Test("contentType matches exact type")
    func contentTypeMatch() {
        let condition = RuleCondition.contentType(.link)
        #expect(condition.matches(content: "https://example.com", contentType: .link, sourceApp: nil))
    }

    @Test("contentType rejects wrong type")
    func contentTypeMismatch() {
        let condition = RuleCondition.contentType(.link)
        #expect(!condition.matches(content: "hello", contentType: .text, sourceApp: nil))
    }

    // MARK: - regexMatch

    @Test("regexMatch matches valid pattern")
    func regexMatch() {
        let condition = RuleCondition.regexMatch(pattern: "^https?://")
        #expect(condition.matches(content: "https://example.com", contentType: .link, sourceApp: nil))
    }

    @Test("regexMatch rejects non-matching content")
    func regexMismatch() {
        let condition = RuleCondition.regexMatch(pattern: "^https?://")
        #expect(!condition.matches(content: "hello world", contentType: .text, sourceApp: nil))
    }

    @Test("regexMatch handles invalid regex gracefully")
    func regexInvalid() {
        let condition = RuleCondition.regexMatch(pattern: "[invalid")
        #expect(!condition.matches(content: "anything", contentType: .text, sourceApp: nil))
    }

    @Test("regexMatch with empty pattern treats as unset — always matches")
    func regexEmpty() {
        let condition = RuleCondition.regexMatch(pattern: "")
        #expect(condition.matches(content: "anything", contentType: .text, sourceApp: nil))
    }

    // MARK: - containsText

    @Test("containsText matches substring")
    func containsMatch() {
        let condition = RuleCondition.containsText(text: "amazon.com")
        #expect(condition.matches(content: "https://amazon.com/dp/123", contentType: .link, sourceApp: nil))
    }

    @Test("containsText is case insensitive")
    func containsCaseInsensitive() {
        let condition = RuleCondition.containsText(text: "HELLO")
        #expect(condition.matches(content: "say hello world", contentType: .text, sourceApp: nil))
    }

    @Test("containsText rejects missing substring")
    func containsMismatch() {
        let condition = RuleCondition.containsText(text: "amazon.com")
        #expect(!condition.matches(content: "https://google.com", contentType: .link, sourceApp: nil))
    }

    @Test("containsText with empty text treats as unset — always matches")
    func containsEmpty() {
        let condition = RuleCondition.containsText(text: "")
        #expect(condition.matches(content: "anything", contentType: .text, sourceApp: nil))
    }

    // MARK: - sourceApp

    @Test("sourceApp matches bundle ID")
    func sourceAppMatch() {
        let condition = RuleCondition.sourceApp(bundleIDs: ["com.apple.Safari"])
        #expect(condition.matches(content: "url", contentType: .link, sourceApp: "com.apple.Safari"))
    }

    @Test("sourceApp rejects different app")
    func sourceAppMismatch() {
        let condition = RuleCondition.sourceApp(bundleIDs: ["com.apple.Safari"])
        #expect(!condition.matches(content: "url", contentType: .link, sourceApp: "com.google.Chrome"))
    }

    @Test("sourceApp matches any in list")
    func sourceAppMultiple() {
        let condition = RuleCondition.sourceApp(bundleIDs: ["com.apple.Safari", "com.google.Chrome"])
        #expect(condition.matches(content: "url", contentType: .link, sourceApp: "com.google.Chrome"))
    }

    @Test("sourceApp rejects nil source when list is non-empty")
    func sourceAppNil() {
        let condition = RuleCondition.sourceApp(bundleIDs: ["com.apple.Safari"])
        #expect(!condition.matches(content: "url", contentType: .link, sourceApp: nil))
    }

    @Test("sourceApp with empty list treats as unset — always matches")
    func sourceAppEmpty() {
        let condition = RuleCondition.sourceApp(bundleIDs: [])
        #expect(condition.matches(content: "anything", contentType: .text, sourceApp: nil))
    }

    @Test("sourceApp with empty list matches even with sourceApp present")
    func sourceAppEmptyWithApp() {
        let condition = RuleCondition.sourceApp(bundleIDs: [])
        #expect(condition.matches(content: "url", contentType: .link, sourceApp: "com.apple.Safari"))
    }

    // MARK: - Codable

    @Test("RuleCondition round-trips through JSON")
    func codableRoundTrip() throws {
        let conditions: [RuleCondition] = [
            .contentType(.link),
            .regexMatch(pattern: "^https"),
            .containsText(text: "test"),
            .sourceApp(bundleIDs: ["com.app"]),
        ]
        let data = try JSONEncoder().encode(conditions)
        let decoded = try JSONDecoder().decode([RuleCondition].self, from: data)
        #expect(decoded.count == 4)
    }

    @Test("sourceApp backward compat: single bundleID decodes to bundleIDs array")
    func codableBackwardCompat() throws {
        let json = """
        [{"type":"sourceApp","bundleID":"com.old.app"}]
        """
        let decoded = try JSONDecoder().decode([RuleCondition].self, from: json.data(using: .utf8)!)
        if case .sourceApp(let ids) = decoded[0] {
            #expect(ids == ["com.old.app"])
        } else {
            #expect(Bool(false), "Expected sourceApp")
        }
    }

    // MARK: - Edge cases

    @Test("regexMatch with special characters in content")
    func regexSpecialChars() {
        let condition = RuleCondition.regexMatch(pattern: "\\$\\d+\\.\\d{2}")
        #expect(condition.matches(content: "Price: $19.99", contentType: .text, sourceApp: nil))
        #expect(!condition.matches(content: "Price: 19.99", contentType: .text, sourceApp: nil))
    }

    @Test("containsText with unicode/emoji")
    func containsUnicode() {
        let condition = RuleCondition.containsText(text: "你好")
        #expect(condition.matches(content: "say 你好 world", contentType: .text, sourceApp: nil))
        #expect(!condition.matches(content: "hello world", contentType: .text, sourceApp: nil))
    }

    @Test("regexMatch with multiline content")
    func regexMultiline() {
        let condition = RuleCondition.regexMatch(pattern: "hello")
        #expect(condition.matches(content: "line1\nhello\nline3", contentType: .text, sourceApp: nil))
    }

    @Test("containsText with very long content")
    func containsLongContent() {
        let longContent = String(repeating: "a", count: 10000) + "needle" + String(repeating: "b", count: 10000)
        let condition = RuleCondition.containsText(text: "needle")
        #expect(condition.matches(content: longContent, contentType: .text, sourceApp: nil))
    }

    @Test("contentType matches all possible types")
    func contentTypeAllTypes() {
        for type in ClipContentType.allCases {
            let condition = RuleCondition.contentType(type)
            #expect(condition.matches(content: "test", contentType: type, sourceApp: nil))
            // Should not match a different type (pick one that's different)
            let otherType: ClipContentType = type == .text ? .link : .text
            #expect(!condition.matches(content: "test", contentType: otherType, sourceApp: nil))
        }
    }

    @Test("sourceApp with nil sourceApp and non-empty list → false")
    func sourceAppNilWithList() {
        let condition = RuleCondition.sourceApp(bundleIDs: ["com.app1", "com.app2"])
        #expect(!condition.matches(content: "test", contentType: .text, sourceApp: nil))
    }

    @Test("Codable preserves empty values")
    func codableEmptyValues() throws {
        let conditions: [RuleCondition] = [
            .regexMatch(pattern: ""),
            .containsText(text: ""),
            .sourceApp(bundleIDs: []),
        ]
        let data = try JSONEncoder().encode(conditions)
        let decoded = try JSONDecoder().decode([RuleCondition].self, from: data)
        #expect(decoded.count == 3)
        // All should match (empty = unset)
        for c in decoded {
            #expect(c.matches(content: "anything", contentType: .text, sourceApp: nil))
        }
    }
}
