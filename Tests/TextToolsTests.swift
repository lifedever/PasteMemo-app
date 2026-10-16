import Foundation
import Testing
@testable import PasteMemo

@Suite("Text toolbox actions")
struct TextToolsTests {

    // MARK: - Base64

    @Test("Base64 round-trips UTF-8, including Chinese and emoji")
    func base64RoundTrip() {
        let text = "你好, PasteMemo 👋"
        let encoded = RuleAction.base64Encode.execute(on: text)
        #expect(encoded == "5L2g5aW9LCBQYXN0ZU1lbW8g8J+Riw==")
        #expect(RuleAction.base64Decode.execute(on: encoded) == text)
    }

    @Test("Base64 decode accepts URL-safe alphabet, missing padding and line breaks")
    func base64Lenient() {
        #expect(TextTools.base64Decode("aGVsbG8gd29y\nbGQ") == "hello world")
        #expect(TextTools.base64Decode("Pz8_Pz8-") == "?????>")
    }

    @Test("Base64 decode leaves text alone when it isn't Base64 for text")
    func base64NotBase64() {
        for text in ["hello", "这不是 base64", "abc", "AAAA"] {
            #expect(TextTools.base64Decode(text) == text)
        }
    }

    // MARK: - JSON

    @Test("JSON format keeps key order and number literals")
    func jsonFormat() {
        let input = #"{"b":1.50,"a":[1,2,{}],"s":"x, y: {z}","e":[]}"#
        let expected = """
        {
          "b": 1.50,
          "a": [
            1,
            2,
            {}
          ],
          "s": "x, y: {z}",
          "e": []
        }
        """
        #expect(RuleAction.jsonFormat.execute(on: input) == expected)
        #expect(RuleAction.jsonMinify.execute(on: expected) == input)
    }

    @Test("JSON handles escaped quotes inside strings")
    func jsonEscapes() {
        let input = #"{"q":"he said \"hi, there\"","p":"a\\"}"#
        #expect(TextTools.minifyJSON(TextTools.formatJSON(input)) == input)
    }

    @Test("JSON actions leave invalid JSON and bare scalars unchanged")
    func jsonInvalid() {
        for text in ["{not json}", "42", "\"just a string\"", "hello"] {
            #expect(TextTools.formatJSON(text) == text)
            #expect(TextTools.minifyJSON(text) == text)
        }
    }

    // MARK: - Naming styles

    @Test("camelCase from snake, kebab, spaced and Pascal names")
    func camelCase() {
        #expect(TextTools.camelCase("user_name") == "userName")
        #expect(TextTools.camelCase("user-name-id") == "userNameId")
        #expect(TextTools.camelCase("User Name") == "userName")
        #expect(TextTools.camelCase("XMLHttpRequest") == "xmlHttpRequest")
        #expect(TextTools.camelCase("order_id_2") == "orderId2")
    }

    @Test("snake_case from camel, acronyms and spaced names")
    func snakeCase() {
        #expect(TextTools.snakeCase("userName") == "user_name")
        #expect(TextTools.snakeCase("XMLHttpRequest") == "xml_http_request")
        #expect(TextTools.snakeCase("userID") == "user_id")
        #expect(TextTools.snakeCase("Order Total") == "order_total")
        #expect(TextTools.snakeCase("v2Config") == "v2_config")
    }

    @Test("naming styles work line by line and keep indentation and empty lines")
    func namingPerLine() {
        #expect(TextTools.snakeCase("firstName\n  lastName\n\n--") == "first_name\n  last_name\n\n--")
    }

    // MARK: - Width

    @Test("full-width ASCII and ideographic space become half-width; 。、 stay")
    func halfWidth() {
        #expect(TextTools.halfWidth("ＡＢＣ１２３，！（测试）　。、") == "ABC123,!(测试) 。、")
    }

    @Test("half-width ASCII becomes full-width")
    func fullWidth() {
        #expect(TextTools.fullWidth("ABC 1,!") == "ＡＢＣ　１，！")
        #expect(TextTools.halfWidth(TextTools.fullWidth("Hello, World 42!")) == "Hello, World 42!")
    }

    // MARK: - 简→繁

    @Test("simplified to traditional is character level")
    func simplifiedToTraditional() {
        #expect(TextTools.simplifiedToTraditional("后台 头发 计算机") == "後台 頭髮 計算機")
        #expect(TextTools.simplifiedToTraditional("ABC 123") == "ABC 123")
    }

    // MARK: - Lines

    @Test("remove duplicate lines keeps the first and blank lines")
    func removeDuplicates() {
        #expect(TextTools.removeDuplicateLines("a\nb\na\n\n b\n\nc") == "a\nb\n\n\nc")
    }

    @Test("sort lines uses natural order and drops blank lines")
    func sortLines() {
        #expect(TextTools.sortLines("file10\nfile2\n\nFile1", ascending: true) == "File1\nfile2\nfile10")
        #expect(TextTools.sortLines("b\na\nc", ascending: false) == "c\nb\na")
    }

    @Test("join lines trims and skips blanks")
    func joinLines() {
        #expect(TextTools.joinLines("  a \n\nb\r\nc ", separator: " ") == "a b c")
        #expect(TextTools.joinLines("第一行\n第二行", separator: "") == "第一行第二行")
    }

    // MARK: - HTML

    @Test("remove HTML tags keeps block breaks, drops scripts, decodes entities")
    func removeHTML() {
        let html = """
        <div><h1>Title</h1><p>Tom &amp; Jerry&nbsp;&lt;3 &#x4F60;&#22909;</p><script>alert(1)</script><br>end</div>
        """
        #expect(TextTools.removeHTMLTags(html) == "Title\nTom & Jerry <3 你好\n\nend")
    }

    @Test("text that merely contains < and > is left alone")
    func removeHTMLNotHTML() {
        for text in ["a < b > c", "if x<3 && y>2", "plain"] {
            #expect(TextTools.removeHTMLTags(text) == text)
        }
    }

    @Test("all toolbox actions are synchronous text transforms usable on capture")
    func descriptors() {
        let actions: [RuleAction] = [.base64Encode, .base64Decode, .jsonFormat, .jsonMinify, .toCamelCase, .toSnakeCase,
                                     .toHalfWidth, .toFullWidth, .simplifiedToTraditional, .removeDuplicateLines,
                                     .sortLines(ascending: true), .joinLines(separator: " "), .removeHTMLTags]
        for action in actions {
            #expect(action.kind == .transform)
            #expect(action.inputKind == .text)
            #expect(!action.requiresManualTrigger)
        }
    }

    @Test("toolbox actions survive an encode / decode round trip")
    func codable() throws {
        let actions: [RuleAction] = [.sortLines(ascending: false), .joinLines(separator: "、"), .jsonFormat]
        let decoded = try JSONDecoder().decode([RuleAction].self, from: JSONEncoder().encode(actions))
        #expect(decoded == actions)
    }
}
