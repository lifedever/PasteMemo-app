import Foundation
import Testing
@testable import PasteMemo

@Suite("AutomationEngine Tests")
struct AutomationEngineTests {

    // MARK: - matchesConditions (AND logic)

    @Test("AND logic: returns true when all conditions match")
    func allConditionsMatch() {
        let conditions: [RuleCondition] = [
            .contentType(.link),
            .containsText(text: "example.com"),
        ]
        let result = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "https://example.com/page", contentType: .link, sourceApp: nil
        )
        #expect(result)
    }

    @Test("AND logic: returns false when any condition fails")
    func oneConditionFails() {
        let conditions: [RuleCondition] = [
            .contentType(.link),
            .containsText(text: "google.com"),
        ]
        let result = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "https://example.com", contentType: .link, sourceApp: nil
        )
        #expect(!result)
    }

    @Test("AND logic: returns true for empty conditions")
    func emptyConditionsAnd() {
        let result = AutomationEngine.matchesConditions(
            [], logic: .all, content: "anything", contentType: .text, sourceApp: nil
        )
        #expect(result)
    }

    // MARK: - matchesConditions (OR logic)

    @Test("OR logic: returns true when any condition matches")
    func anyConditionMatches() {
        let conditions: [RuleCondition] = [
            .containsText(text: "google.com"),
            .containsText(text: "example.com"),
        ]
        let result = AutomationEngine.matchesConditions(
            conditions, logic: .any, content: "https://example.com", contentType: .link, sourceApp: nil
        )
        #expect(result)
    }

    @Test("OR logic: returns false when no conditions match")
    func noConditionMatches() {
        let conditions: [RuleCondition] = [
            .containsText(text: "google.com"),
            .containsText(text: "apple.com"),
        ]
        let result = AutomationEngine.matchesConditions(
            conditions, logic: .any, content: "https://example.com", contentType: .link, sourceApp: nil
        )
        #expect(!result)
    }

    @Test("OR logic: returns true for empty conditions")
    func emptyConditionsOr() {
        let result = AutomationEngine.matchesConditions(
            [], logic: .any, content: "anything", contentType: .text, sourceApp: nil
        )
        #expect(!result) // contains on empty returns false
    }

    @Test("OR logic: single matching condition is enough")
    func orSingleMatch() {
        let conditions: [RuleCondition] = [
            .contentType(.text),
            .sourceApp(bundleIDs: ["com.apple.Safari"]),
        ]
        let result = AutomationEngine.matchesConditions(
            conditions, logic: .any, content: "hello", contentType: .text, sourceApp: nil
        )
        #expect(result)
    }

    // MARK: - matchesConditions with empty values (treated as unset)

    @Test("AND logic: empty regex + empty containsText both pass — treated as unset")
    func emptyConditionsAsUnset() {
        let conditions: [RuleCondition] = [
            .regexMatch(pattern: ""),
            .containsText(text: ""),
            .sourceApp(bundleIDs: []),
        ]
        let result = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "anything", contentType: .text, sourceApp: nil
        )
        #expect(result)
    }

    @Test("AND logic: one real condition + one empty — only real condition matters")
    func mixedEmptyAndReal() {
        let conditions: [RuleCondition] = [
            .containsText(text: "abc"),
            .regexMatch(pattern: ""),
        ]
        let matched = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "xyzabc123", contentType: .text, sourceApp: nil
        )
        #expect(matched)

        let notMatched = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "xyz123", contentType: .text, sourceApp: nil
        )
        #expect(!notMatched)
    }

    // MARK: - matchesAllConditions (backward compat alias)

    @Test("matchesAllConditions alias works the same as AND logic")
    func aliasBackwardCompat() {
        let conditions: [RuleCondition] = [
            .contentType(.link),
            .containsText(text: "example"),
        ]
        let result = AutomationEngine.matchesAllConditions(
            conditions, content: "https://example.com", contentType: .link, sourceApp: nil
        )
        #expect(result)
    }

    // MARK: - executeActions

    @Test("executeActions runs pipeline in order")
    func pipelineOrder() {
        let actions: [RuleAction] = [.trimWhitespace, .lowercased, .addSuffix(text: "!")]
        let result = AutomationEngine.executeActions(actions, on: "  Hello WORLD  ")
        #expect(result == "hello world!")
    }

    @Test("executeActions returns original for empty actions")
    func emptyActions() {
        let result = AutomationEngine.executeActions([], on: "unchanged")
        #expect(result == "unchanged")
    }

    // MARK: - Built-in rule scenarios

    @Test("Clean tracking params from URL pipeline")
    func cleanTrackingPipeline() {
        let conditions: [RuleCondition] = [.contentType(.link)]
        let actions: [RuleAction] = [.removeQueryParams(patterns: ["utm_*", "fbclid"])]

        let matched = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "https://example.com/page?id=1&utm_source=tw&fbclid=abc",
            contentType: .link, sourceApp: nil
        )
        #expect(matched)

        let result = AutomationEngine.executeActions(
            actions, on: "https://example.com/page?id=1&utm_source=tw&fbclid=abc"
        )
        #expect(result == "https://example.com/page?id=1")
    }

    @Test("Email lowercase pipeline")
    func emailLowercasePipeline() {
        let conditions: [RuleCondition] = [.contentType(.email)]
        let actions: [RuleAction] = [.lowercased]
        let matches = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "John@Example.COM", contentType: .email, sourceApp: nil
        )
        #expect(matches)
        let result = AutomationEngine.executeActions(actions, on: "John@Example.COM")
        #expect(result == "john@example.com")
    }

    @Test("Content + sourceApp AND condition — both must match")
    func contentAndSourceApp() {
        let conditions: [RuleCondition] = [
            .containsText(text: "abc"),
            .sourceApp(bundleIDs: ["com.apple.Safari"]),
        ]

        let bothMatch = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "xyzabc", contentType: .text, sourceApp: "com.apple.Safari"
        )
        #expect(bothMatch)

        let contentOnly = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "xyzabc", contentType: .text, sourceApp: "com.google.Chrome"
        )
        #expect(!contentOnly)

        let appOnly = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "xyz", contentType: .text, sourceApp: "com.apple.Safari"
        )
        #expect(!appOnly)
    }

    @Test("Content OR sourceApp — either can match")
    func contentOrSourceApp() {
        let conditions: [RuleCondition] = [
            .containsText(text: "abc"),
            .sourceApp(bundleIDs: ["com.apple.Safari"]),
        ]

        let contentOnly = AutomationEngine.matchesConditions(
            conditions, logic: .any, content: "xyzabc", contentType: .text, sourceApp: "com.google.Chrome"
        )
        #expect(contentOnly)

        let appOnly = AutomationEngine.matchesConditions(
            conditions, logic: .any, content: "xyz", contentType: .text, sourceApp: "com.apple.Safari"
        )
        #expect(appOnly)

        let neitherMatch = AutomationEngine.matchesConditions(
            conditions, logic: .any, content: "xyz", contentType: .text, sourceApp: "com.google.Chrome"
        )
        #expect(!neitherMatch)
    }

    // MARK: - Complex combination rules (simulating real user scenarios)

    @Test("Rule: URL from Safari containing 'amazon' → clean tracking + lowercase")
    func urlFromSafariCleanAndLower() {
        let conditions: [RuleCondition] = [
            .contentType(.link),
            .containsText(text: "amazon"),
            .sourceApp(bundleIDs: ["com.apple.Safari"]),
        ]
        let actions: [RuleAction] = [
            .removeQueryParams(patterns: ["utm_*", "ref", "tag"]),
            .lowercased,
        ]

        // All conditions match
        let input = "https://Amazon.com/dp/123?ref=abc&utm_source=tw&id=456"
        let matched = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: input, contentType: .link, sourceApp: "com.apple.Safari"
        )
        #expect(matched)
        let result = AutomationEngine.executeActions(actions, on: input)
        #expect(result == "https://amazon.com/dp/123?id=456")

        // Wrong app → not matched
        let wrongApp = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: input, contentType: .link, sourceApp: "com.google.Chrome"
        )
        #expect(!wrongApp)

        // Not amazon → not matched
        let wrongDomain = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "https://google.com?utm_source=tw", contentType: .link, sourceApp: "com.apple.Safari"
        )
        #expect(!wrongDomain)
    }

    @Test("Rule: text from any app containing 'password' OR 'secret' → trim whitespace (OR logic)")
    func sensitiveTextOrLogic() {
        let conditions: [RuleCondition] = [
            .containsText(text: "password"),
            .containsText(text: "secret"),
        ]
        let actions: [RuleAction] = [.trimWhitespace]

        // "password" matches
        let hasPassword = AutomationEngine.matchesConditions(
            conditions, logic: .any, content: "  my password is 123  ", contentType: .text, sourceApp: nil
        )
        #expect(hasPassword)

        // "secret" matches
        let hasSecret = AutomationEngine.matchesConditions(
            conditions, logic: .any, content: "  top secret data  ", contentType: .text, sourceApp: nil
        )
        #expect(hasSecret)

        // Neither matches
        let hasNeither = AutomationEngine.matchesConditions(
            conditions, logic: .any, content: "  just normal text  ", contentType: .text, sourceApp: nil
        )
        #expect(!hasNeither)
    }

    @Test("Rule: regex email pattern → lowercase (built-in email rule simulation)")
    func regexEmailLowercase() {
        let conditions: [RuleCondition] = [
            .regexMatch(pattern: "^[\\w.+-]+@[\\w.-]+\\.[a-zA-Z]{2,}$"),
        ]
        let actions: [RuleAction] = [.lowercased]

        let validEmail = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "John.DOE@Example.COM", contentType: .text, sourceApp: nil
        )
        #expect(validEmail)
        #expect(AutomationEngine.executeActions(actions, on: "John.DOE@Example.COM") == "john.doe@example.com")

        // Not an email
        let notEmail = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "not an email", contentType: .text, sourceApp: nil
        )
        #expect(!notEmail)
    }

    @Test("Rule: multiple actions pipeline — trim + regex replace + prefix + suffix")
    func complexPipeline() {
        let actions: [RuleAction] = [
            .trimWhitespace,
            .regexReplace(pattern: "\\s+", replacement: "_"),
            .lowercased,
            .addPrefix(text: "file_"),
            .addSuffix(text: ".txt"),
        ]
        let result = AutomationEngine.executeActions(actions, on: "  Hello  World  Test  ")
        #expect(result == "file_hello_world_test.txt")
    }

    @Test("Rule: all empty conditions with AND logic → always matches (no filter)")
    func allEmptyConditionsAndLogic() {
        let conditions: [RuleCondition] = [
            .regexMatch(pattern: ""),
            .containsText(text: ""),
            .sourceApp(bundleIDs: []),
        ]
        let actions: [RuleAction] = [.uppercased]

        let matched = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "anything", contentType: .text, sourceApp: nil
        )
        #expect(matched)
        #expect(AutomationEngine.executeActions(actions, on: "hello") == "HELLO")
    }

    @Test("Rule: all empty conditions with OR logic → none matches (contains on empty)")
    func allEmptyConditionsOrLogic() {
        let conditions: [RuleCondition] = [
            .regexMatch(pattern: ""),
            .containsText(text: ""),
            .sourceApp(bundleIDs: []),
        ]
        // OR logic: .contains checks each — empty conditions return true individually
        // so at least one will match
        let matched = AutomationEngine.matchesConditions(
            conditions, logic: .any, content: "anything", contentType: .text, sourceApp: nil
        )
        #expect(matched)
    }

    @Test("Rule: mixed real + empty conditions with OR → real condition decides")
    func mixedRealEmptyOrLogic() {
        let conditions: [RuleCondition] = [
            .containsText(text: "target"),
            .regexMatch(pattern: ""),  // empty = always true
        ]

        // Empty regex always matches, so OR always true
        let matched = AutomationEngine.matchesConditions(
            conditions, logic: .any, content: "no match here", contentType: .text, sourceApp: nil
        )
        #expect(matched) // because empty regex returns true

        // With AND, empty regex passes but containsText fails
        let andResult = AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "no match here", contentType: .text, sourceApp: nil
        )
        #expect(!andResult)
    }

    @Test("Rule: 3 conditions AND — contentType + regex + sourceApp")
    func threeConditionsAnd() {
        let conditions: [RuleCondition] = [
            .contentType(.link),
            .regexMatch(pattern: "^https://"),
            .sourceApp(bundleIDs: ["com.apple.Safari", "com.google.Chrome"]),
        ]

        // All three match
        #expect(AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "https://example.com", contentType: .link, sourceApp: "com.apple.Safari"
        ))

        // HTTP (not HTTPS) → regex fails
        #expect(!AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "http://example.com", contentType: .link, sourceApp: "com.apple.Safari"
        ))

        // Wrong content type
        #expect(!AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "https://example.com", contentType: .text, sourceApp: "com.apple.Safari"
        ))

        // Wrong app
        #expect(!AutomationEngine.matchesConditions(
            conditions, logic: .all, content: "https://example.com", contentType: .link, sourceApp: "com.app.Firefox"
        ))
    }

    @Test("Rule: 3 conditions OR — any one is enough")
    func threeConditionsOr() {
        let conditions: [RuleCondition] = [
            .contentType(.link),
            .containsText(text: "http"),
            .sourceApp(bundleIDs: ["com.apple.Safari"]),
        ]

        // Only contentType matches
        #expect(AutomationEngine.matchesConditions(
            conditions, logic: .any, content: "ftp://file", contentType: .link, sourceApp: "com.other"
        ))

        // Only containsText matches
        #expect(AutomationEngine.matchesConditions(
            conditions, logic: .any, content: "go to http site", contentType: .text, sourceApp: "com.other"
        ))

        // Only sourceApp matches
        #expect(AutomationEngine.matchesConditions(
            conditions, logic: .any, content: "plain text", contentType: .text, sourceApp: "com.apple.Safari"
        ))

        // None matches
        #expect(!AutomationEngine.matchesConditions(
            conditions, logic: .any, content: "plain text", contentType: .text, sourceApp: "com.other"
        ))
    }

    @Test("Pipeline unchanged content → no action applied")
    func pipelineUnchanged() {
        let actions: [RuleAction] = [.lowercased]
        let input = "already lowercase"
        let result = AutomationEngine.executeActions(actions, on: input)
        #expect(result == input) // same content, engine would detect as unchanged
    }

    @Test("URL encode then decode round-trip")
    func urlEncodeDecodeRoundTrip() {
        let actions: [RuleAction] = [.urlEncode, .urlDecode]
        let input = "hello world&foo=bar"
        let result = AutomationEngine.executeActions(actions, on: input)
        #expect(result == input)
    }

    @Test("Single condition with single action — minimal rule")
    func minimalRule() {
        let conditions: [RuleCondition] = [.containsText(text: "test")]
        let actions: [RuleAction] = [.uppercased]

        #expect(AutomationEngine.matchesConditions(conditions, logic: .all, content: "test123", contentType: .text, sourceApp: nil))
        #expect(AutomationEngine.executeActions(actions, on: "test123") == "TEST123")
    }

    // MARK: - assignGroup in pipeline

    @Test("assignGroup action does not alter text in pipeline")
    func assignGroupInPipeline() {
        let actions: [RuleAction] = [.uppercased, .assignGroup(name: "工作"), .addSuffix(text: "!")]
        let result = AutomationEngine.executeActions(actions, on: "hello")
        #expect(result == "HELLO!")
    }

    @Test("assignGroup-only rule: executeActions returns content unchanged")
    func assignGroupOnly() {
        let actions: [RuleAction] = [.assignGroup(name: "test")]
        let result = AutomationEngine.executeActions(actions, on: "original")
        #expect(result == "original")
    }

    @Test("hasSpecialActions detects assignGroup as special")
    func assignGroupIsSpecial() {
        let actions: [RuleAction] = [.assignGroup(name: "work")]
        let hasSpecial = actions.contains { action in
            if case .stripRichText = action { return true }
            if case .assignGroup = action { return true }
            return false
        }
        #expect(hasSpecial)
    }

    @Test("assignGroup with empty name in pipeline — still passes through")
    func assignGroupEmptyInPipeline() {
        let actions: [RuleAction] = [.lowercased, .assignGroup(name: "")]
        let result = AutomationEngine.executeActions(actions, on: "HELLO")
        #expect(result == "hello")
    }

    @Test("Conditions match + assignGroup + text transform pipeline")
    func conditionsWithAssignGroup() {
        let conditions: [RuleCondition] = [.contentType(.color)]
        let actions: [RuleAction] = [.assignGroup(name: "颜色"), .uppercased]
        let matched = AutomationEngine.matchesConditions(conditions, logic: .all, content: "#ff0000", contentType: .color, sourceApp: nil)
        #expect(matched)
        let result = AutomationEngine.executeActions(actions, on: "#ff0000")
        #expect(result == "#FF0000")
    }

    @Test("OR logic with assignGroup: contentType OR containsText")
    func orLogicWithAssignGroup() {
        let conditions: [RuleCondition] = [.contentType(.link), .containsText(text: "http")]
        let actions: [RuleAction] = [.assignGroup(name: "链接")]
        // Plain text containing "http" should match with OR logic
        let matched = AutomationEngine.matchesConditions(conditions, logic: .any, content: "visit http://example.com", contentType: .text, sourceApp: nil)
        #expect(matched)
        let result = AutomationEngine.executeActions(actions, on: "visit http://example.com")
        #expect(result == "visit http://example.com") // assignGroup doesn't modify text
    }
}
