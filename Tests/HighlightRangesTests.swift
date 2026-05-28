import Foundation
import Testing
@testable import PasteMemo

@Suite("Search highlight range computation")
@MainActor
struct HighlightRangesTests {

    @Test("Single ASCII token, single occurrence")
    func singleTokenOnce() {
        let content = "hello world"
        let ranges = NativeTextView.highlightRanges(in: content, tokens: ["world"])
        #expect(ranges.count == 1)
        #expect(ranges.first == NSRange(location: 6, length: 5))
    }

    @Test("Single token with multiple occurrences (all returned)")
    func singleTokenMultipleHits() {
        let content = "foo bar foo baz foo"
        let ranges = NativeTextView.highlightRanges(in: content, tokens: ["foo"])
        #expect(ranges.count == 3)
        #expect(ranges[0] == NSRange(location: 0, length: 3))
        #expect(ranges[1] == NSRange(location: 8, length: 3))
        #expect(ranges[2] == NSRange(location: 16, length: 3))
    }

    @Test("Case-insensitive match")
    func caseInsensitive() {
        let content = "Hello HELLO hello"
        let ranges = NativeTextView.highlightRanges(in: content, tokens: ["hello"])
        #expect(ranges.count == 3)
    }

    @Test("Multiple tokens — each scanned independently")
    func multipleTokensIndependent() {
        let content = "学习笔记和学习方法都很重要"
        let ranges = NativeTextView.highlightRanges(in: content, tokens: ["学习", "重要"])
        // "学习" appears twice (positions 0 and 5 in CJK chars, but NSRange is UTF-16),
        // "重要" appears once
        #expect(ranges.count == 3)
    }

    @Test("Mixed CJK + ASCII tokens both highlighted")
    func mixedCjkAscii() {
        let content = "学习 swift 的笔记"
        let ranges = NativeTextView.highlightRanges(in: content, tokens: ["学习", "swift"])
        #expect(ranges.count == 2)
    }

    @Test("Empty tokens list yields no ranges")
    func emptyTokens() {
        let ranges = NativeTextView.highlightRanges(in: "any content", tokens: [])
        #expect(ranges.isEmpty)
    }

    @Test("Empty string token is skipped (not infinite loop)")
    func emptyTokenSkipped() {
        let ranges = NativeTextView.highlightRanges(in: "any content", tokens: [""])
        #expect(ranges.isEmpty)
    }

    @Test("No match returns empty")
    func noMatch() {
        let ranges = NativeTextView.highlightRanges(in: "hello world", tokens: ["zzz"])
        #expect(ranges.isEmpty)
    }

    @Test("Empty content with non-empty tokens returns empty")
    func emptyContent() {
        let ranges = NativeTextView.highlightRanges(in: "", tokens: ["foo"])
        #expect(ranges.isEmpty)
    }

    @Test("Match at start and end of content")
    func boundaryHits() {
        let content = "abc middle abc"
        let ranges = NativeTextView.highlightRanges(in: content, tokens: ["abc"])
        #expect(ranges.count == 2)
        #expect(ranges[0].location == 0)
        #expect(ranges[1].location == 11)
    }

    @Test("Adjacent matches without overlap")
    func adjacentMatches() {
        // 'abab' contains 'ab' at index 0 and 2; matches don't overlap (cursor advances by length)
        let ranges = NativeTextView.highlightRanges(in: "abab", tokens: ["ab"])
        #expect(ranges.count == 2)
        #expect(ranges[0] == NSRange(location: 0, length: 2))
        #expect(ranges[1] == NSRange(location: 2, length: 2))
    }
}
