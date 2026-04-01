import Foundation
import Testing
@testable import PasteMemo

@Suite("RuleAction Tests")
struct RuleActionTests {

    // MARK: - lowercased

    @Test("lowercased converts text")
    func lowercased() {
        let result = RuleAction.lowercased.execute(on: "Hello WORLD")
        #expect(result == "hello world")
    }

    @Test("lowercased on already lowercase is no-op")
    func lowercasedNoOp() {
        let result = RuleAction.lowercased.execute(on: "hello")
        #expect(result == "hello")
    }

    // MARK: - uppercased

    @Test("uppercased converts text")
    func uppercased() {
        let result = RuleAction.uppercased.execute(on: "Hello World")
        #expect(result == "HELLO WORLD")
    }

    // MARK: - trimWhitespace

    @Test("trimWhitespace removes leading and trailing whitespace")
    func trimWhitespace() {
        let result = RuleAction.trimWhitespace.execute(on: "  hello world  \n")
        #expect(result == "hello world")
    }

    @Test("trimWhitespace on clean string is no-op")
    func trimWhitespaceNoOp() {
        let result = RuleAction.trimWhitespace.execute(on: "hello")
        #expect(result == "hello")
    }

    // MARK: - removeBlankLines

    @Test("removeBlankLines collapses all blank lines")
    func removeBlankLines() {
        let input = "line1\n\n\n\nline2\n\n\n\n\nline3"
        let result = RuleAction.removeBlankLines.execute(on: input)
        #expect(result == "line1\nline2\nline3")
    }

    @Test("removeBlankLines preserves single newlines")
    func preserveSingleNewline() {
        let input = "line1\nline2\nline3"
        let result = RuleAction.removeBlankLines.execute(on: input)
        #expect(result == "line1\nline2\nline3")
    }

    // MARK: - urlEncode

    @Test("urlEncode encodes special characters")
    func urlEncode() {
        let result = RuleAction.urlEncode.execute(on: "hello world&foo=bar")
        #expect(result.contains("%20"))
        #expect(result.contains("%26"))
        #expect(!result.contains(" "))
    }

    @Test("urlEncode preserves unreserved characters")
    func urlEncodeUnreserved() {
        let result = RuleAction.urlEncode.execute(on: "hello-world_test.txt~")
        #expect(result == "hello-world_test.txt~")
    }

    // MARK: - urlDecode

    @Test("urlDecode decodes percent encoding")
    func urlDecode() {
        let result = RuleAction.urlDecode.execute(on: "hello%20world%26foo%3Dbar")
        #expect(result == "hello world&foo=bar")
    }

    @Test("urlDecode on plain text is no-op")
    func urlDecodeNoOp() {
        let result = RuleAction.urlDecode.execute(on: "plain text")
        #expect(result == "plain text")
    }

    // MARK: - removeQueryParams

    @Test("removeQueryParams removes utm_* params")
    func removeUTM() {
        let input = "https://example.com/page?id=123&utm_source=twitter&utm_medium=social&ref=abc"
        let result = RuleAction.removeQueryParams(patterns: ["utm_*"]).execute(on: input)
        #expect(result == "https://example.com/page?id=123&ref=abc")
    }

    @Test("removeQueryParams removes exact match params")
    func removeExact() {
        let input = "https://example.com?a=1&fbclid=abc&b=2"
        let result = RuleAction.removeQueryParams(patterns: ["fbclid"]).execute(on: input)
        #expect(result == "https://example.com?a=1&b=2")
    }

    @Test("removeQueryParams removes all params leaves clean URL")
    func removeAllParams() {
        let input = "https://example.com?utm_source=tw"
        let result = RuleAction.removeQueryParams(patterns: ["utm_*"]).execute(on: input)
        #expect(result == "https://example.com")
    }

    @Test("removeQueryParams handles URL without query string")
    func noQueryString() {
        let input = "https://example.com/page"
        let result = RuleAction.removeQueryParams(patterns: ["utm_*"]).execute(on: input)
        #expect(result == "https://example.com/page")
    }

    @Test("removeQueryParams handles non-URL text")
    func nonURL() {
        let input = "just plain text"
        let result = RuleAction.removeQueryParams(patterns: ["utm_*"]).execute(on: input)
        #expect(result == "just plain text")
    }

    @Test("removeQueryParams removes multiple wildcard patterns")
    func removeMultipleWildcard() {
        let input = "https://example.com?utm_source=tw&mc_cid=abc&id=1&mc_eid=def"
        let result = RuleAction.removeQueryParams(patterns: ["utm_*", "mc_*"]).execute(on: input)
        #expect(result == "https://example.com?id=1")
    }

    // MARK: - regexReplace

    @Test("regexReplace replaces matched pattern")
    func regexReplace() {
        let result = RuleAction.regexReplace(pattern: "\\d+", replacement: "#").execute(on: "abc123def456")
        #expect(result == "abc#def#")
    }

    @Test("regexReplace handles invalid regex gracefully")
    func regexReplaceInvalid() {
        let result = RuleAction.regexReplace(pattern: "[invalid", replacement: "x").execute(on: "text")
        #expect(result == "text")
    }

    @Test("regexReplace with no match returns original")
    func regexReplaceNoMatch() {
        let result = RuleAction.regexReplace(pattern: "\\d+", replacement: "#").execute(on: "no digits here")
        #expect(result == "no digits here")
    }

    // MARK: - addPrefix / addSuffix

    @Test("addPrefix prepends text")
    func addPrefix() {
        let result = RuleAction.addPrefix(text: "> ").execute(on: "quoted text")
        #expect(result == "> quoted text")
    }

    @Test("addSuffix appends text")
    func addSuffix() {
        let result = RuleAction.addSuffix(text: " (copied)").execute(on: "content")
        #expect(result == "content (copied)")
    }

    @Test("addPrefix with empty text is no-op")
    func addPrefixEmpty() {
        let result = RuleAction.addPrefix(text: "").execute(on: "content")
        #expect(result == "content")
    }

    @Test("addSuffix with empty text is no-op")
    func addSuffixEmpty() {
        let result = RuleAction.addSuffix(text: "").execute(on: "content")
        #expect(result == "content")
    }

    // MARK: - stripRichText

    @Test("stripRichText returns content unchanged (handled at ClipboardManager level)")
    func stripRichText() {
        let result = RuleAction.stripRichText.execute(on: "hello world")
        #expect(result == "hello world")
    }

    // MARK: - assignGroup

    @Test("assignGroup does not modify content text")
    func assignGroupNoOp() {
        let result = RuleAction.assignGroup(name: "工作").execute(on: "hello")
        #expect(result == "hello")
    }

    @Test("assignGroup with empty name does not modify content")
    func assignGroupEmptyName() {
        let result = RuleAction.assignGroup(name: "").execute(on: "test")
        #expect(result == "test")
    }

    // MARK: - Pipeline

    @Test("Actions execute as pipeline — order matters")
    func pipeline() {
        let actions: [RuleAction] = [.trimWhitespace, .lowercased]
        let result = AutomationEngine.executeActions(actions, on: "  Hello WORLD  ")
        #expect(result == "hello world")
    }

    @Test("Pipeline: uppercase then add suffix")
    func pipelineUpperSuffix() {
        let actions: [RuleAction] = [.uppercased, .addSuffix(text: ".jpg")]
        let result = AutomationEngine.executeActions(actions, on: "photo")
        #expect(result == "PHOTO.jpg")
    }

    @Test("Pipeline: trim then regex replace then prefix")
    func pipelineComplex() {
        let actions: [RuleAction] = [
            .trimWhitespace,
            .regexReplace(pattern: "\\s+", replacement: "-"),
            .addPrefix(text: "slug-"),
        ]
        let result = AutomationEngine.executeActions(actions, on: "  hello  world  ")
        #expect(result == "slug-hello-world")
    }

    // MARK: - Codable

    @Test("RuleAction round-trips through JSON")
    func codableRoundTrip() throws {
        let actions: [RuleAction] = [
            .lowercased,
            .uppercased,
            .trimWhitespace,
            .removeBlankLines,
            .urlEncode,
            .urlDecode,
            .removeQueryParams(patterns: ["utm_*", "fbclid"]),
            .regexReplace(pattern: "\\d+", replacement: "#"),
            .addPrefix(text: "> "),
            .addSuffix(text: "!"),
            .stripRichText,
            .assignGroup(name: "工作"),
        ]
        let data = try JSONEncoder().encode(actions)
        let decoded = try JSONDecoder().decode([RuleAction].self, from: data)
        #expect(decoded.count == 12)
        let result = decoded[6].execute(on: "https://x.com?utm_source=tw&id=1")
        #expect(result == "https://x.com?id=1")
    }

    // MARK: - Edge cases

    @Test("lowercased with unicode")
    func lowercasedUnicode() {
        let result = RuleAction.lowercased.execute(on: "ÜBER Straße")
        #expect(result == "über straße")
    }

    @Test("uppercased with unicode")
    func uppercasedUnicode() {
        let result = RuleAction.uppercased.execute(on: "über straße")
        #expect(result == "ÜBER STRASSE")
    }

    @Test("trimWhitespace with only whitespace")
    func trimWhitespaceOnly() {
        let result = RuleAction.trimWhitespace.execute(on: "   \n\t  ")
        #expect(result == "")
    }

    @Test("trimWhitespace with empty string")
    func trimWhitespaceEmpty() {
        let result = RuleAction.trimWhitespace.execute(on: "")
        #expect(result == "")
    }

    @Test("removeBlankLines with single line")
    func removeBlankLinesSingle() {
        let result = RuleAction.removeBlankLines.execute(on: "hello")
        #expect(result == "hello")
    }

    @Test("urlEncode with empty string")
    func urlEncodeEmpty() {
        let result = RuleAction.urlEncode.execute(on: "")
        #expect(result == "")
    }

    @Test("urlDecode with invalid percent encoding")
    func urlDecodeInvalid() {
        let result = RuleAction.urlDecode.execute(on: "%ZZ invalid")
        #expect(result == "%ZZ invalid") // returns original
    }

    @Test("removeQueryParams with URL fragment")
    func removeQueryParamsWithFragment() {
        let input = "https://example.com?utm_source=tw&id=1#section"
        let result = RuleAction.removeQueryParams(patterns: ["utm_*"]).execute(on: input)
        #expect(result.contains("id=1"))
        #expect(result.contains("#section"))
        #expect(!result.contains("utm_source"))
    }

    @Test("regexReplace with capture groups")
    func regexReplaceCapture() {
        let result = RuleAction.regexReplace(pattern: "(\\w+)@(\\w+)", replacement: "$1 at $2")
            .execute(on: "user@domain")
        #expect(result == "user at domain")
    }

    @Test("addPrefix and addSuffix with multiline")
    func prefixSuffixMultiline() {
        let input = "line1\nline2"
        let result = RuleAction.addPrefix(text: "START:").execute(on: input)
        #expect(result == "START:line1\nline2")
        let result2 = RuleAction.addSuffix(text: ":END").execute(on: input)
        #expect(result2 == "line1\nline2:END")
    }

    @Test("All actions on empty string produce valid output")
    func allActionsEmptyInput() {
        let actions: [RuleAction] = [
            .lowercased, .uppercased, .trimWhitespace, .removeBlankLines,
            .urlEncode, .urlDecode, .stripRichText,
            .removeQueryParams(patterns: ["utm_*"]),
            .regexReplace(pattern: "\\d+", replacement: "#"),
            .addPrefix(text: "pre"), .addSuffix(text: "suf"),
            .assignGroup(name: "test"),
        ]
        for action in actions {
            let result = action.execute(on: "")
            // Should not crash, prefix/suffix add text, others return empty
            switch action {
            case .addPrefix: #expect(result == "pre")
            case .addSuffix: #expect(result == "suf")
            default: #expect(result == "")
            }
        }
    }
}
