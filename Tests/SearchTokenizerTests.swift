import Foundation
import Testing
@testable import PasteMemo

@Suite("Search tokenizer (multi-token AND search)")
@MainActor
struct SearchTokenizerTests {

    @Test("Single token is unchanged")
    func singleToken() {
        #expect(ClipItemStore.tokenizeSearchInput("abc") == ["abc"])
    }

    @Test("Two ASCII tokens separated by space")
    func twoAsciiTokens() {
        #expect(ClipItemStore.tokenizeSearchInput("abc def") == ["abc", "def"])
    }

    @Test("Multiple internal spaces collapse")
    func multipleInternalSpaces() {
        #expect(ClipItemStore.tokenizeSearchInput("abc   def") == ["abc", "def"])
    }

    @Test("Leading and trailing whitespace stripped")
    func leadingTrailingTrim() {
        #expect(ClipItemStore.tokenizeSearchInput("  abc  ") == ["abc"])
    }

    @Test("CJK tokens separated by space")
    func cjkTokens() {
        #expect(ClipItemStore.tokenizeSearchInput("学习 笔记") == ["学习", "笔记"])
    }

    @Test("Mixed CJK + ASCII")
    func mixedCjkAscii() {
        #expect(ClipItemStore.tokenizeSearchInput("学习 swift") == ["学习", "swift"])
    }

    @Test("Empty input → empty tokens")
    func emptyInput() {
        #expect(ClipItemStore.tokenizeSearchInput("") == [])
    }

    @Test("Whitespace-only input → empty tokens")
    func whitespaceOnly() {
        #expect(ClipItemStore.tokenizeSearchInput("    ") == [])
    }

    @Test("Tab and full-width space treated as whitespace")
    func tabAndFullWidthSpace() {
        // \t = tab, \u{3000} = full-width (ideographic) space
        #expect(ClipItemStore.tokenizeSearchInput("abc\tdef") == ["abc", "def"])
        #expect(ClipItemStore.tokenizeSearchInput("学习\u{3000}笔记") == ["学习", "笔记"])
    }

    @Test("Three+ tokens all preserved in order")
    func threeTokens() {
        #expect(ClipItemStore.tokenizeSearchInput("a b c") == ["a", "b", "c"])
    }
}
