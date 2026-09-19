import Foundation
import SwiftData
import Testing
@testable import PasteMemo

/// OpenAI-compatible client: request shape, reply parsing, fence stripping, Base URL
/// normalisation, the send guard, and the executor's AI path with a fake transport.
@Suite("AIClient", .serialized)
struct AIClientTests {

    private struct FakeTransport: AITransport {
        let status: Int
        let body: String
        let onRequest: (@Sendable (URLRequest) -> Void)?
        init(status: Int = 200, body: String, onRequest: (@Sendable (URLRequest) -> Void)? = nil) {
            self.status = status; self.body = body; self.onRequest = onRequest
        }
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            onRequest?(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private let config = AIClientConfig(baseURL: "https://api.example.com/v1", apiKey: "sk-test",
                                        model: "demo-model", timeout: 30, temperature: 0.2)

    private static let okBody = #"{"choices":[{"message":{"role":"assistant","content":"Hello, world"}}],"usage":{"total_tokens":9}}"#

    // MARK: - Base URL

    @Test("endpoint appends /chat/completions and tolerates trailing slashes")
    func endpoint() {
        #expect(AIClient.endpointURL(baseURL: "https://api.openai.com/v1")?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(AIClient.endpointURL(baseURL: "https://api.openai.com/v1///")?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(AIClient.endpointURL(baseURL: "http://localhost:11434/v1/chat/completions")?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(AIClient.endpointURL(baseURL: "") == nil)
        #expect(AIClient.endpointURL(baseURL: "ftp://x") == nil)
        #expect(AIClient.endpointURL(baseURL: "not a url") == nil)
    }

    // MARK: - Request

    @Test("request carries bearer key, model, temperature, both messages, no streaming")
    func requestShape() async throws {
        final class Box: @unchecked Sendable { var request: URLRequest? }
        let box = Box()
        let client = AIClient(config: config, transport: FakeTransport(body: Self.okBody) { box.request = $0 })
        _ = try await client.transform(prompt: "Translate to English", content: "你好")

        let req = try #require(box.request)
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(req.timeoutInterval == 30)
        let json = try #require(JSONSerialization.jsonObject(with: req.httpBody!) as? [String: Any])
        #expect(json["model"] as? String == "demo-model")
        #expect(json["stream"] as? Bool == false)
        #expect((json["temperature"] as? Double).map { abs($0 - 0.2) < 0.001 } == true)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[1]["content"]?.hasPrefix("Translate to English") == true)
        #expect(messages[1]["content"]?.hasSuffix("你好") == true)
    }

    @Test("no Authorization header when the key is empty (local servers)")
    func noKey() async throws {
        final class Box: @unchecked Sendable { var request: URLRequest? }
        let box = Box()
        var cfg = config; cfg.apiKey = ""
        let client = AIClient(config: cfg, transport: FakeTransport(body: Self.okBody) { box.request = $0 })
        _ = try await client.transform(prompt: "x", content: "y")
        #expect(box.request?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - Reply

    @Test("reply content is trimmed and fences are stripped")
    func replyParsing() async throws {
        let fenced = #"{"choices":[{"message":{"content":"```text\nhello\n```"}}]}"#
        let client = AIClient(config: config, transport: FakeTransport(body: fenced))
        #expect(try await client.transform(prompt: "x", content: "y") == "hello")
    }

    @Test("array-of-parts content is joined")
    func partsContent() async throws {
        let parts = #"{"choices":[{"message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}}]}"#
        let client = AIClient(config: config, transport: FakeTransport(body: parts))
        #expect(try await client.transform(prompt: "x", content: "y") == "ab")
    }

    @Test("HTTP error surfaces status and provider message")
    func httpError() async {
        let body = #"{"error":{"message":"The model does not exist","type":"Not Found"}}"#
        let client = AIClient(config: config, transport: FakeTransport(status: 404, body: body))
        await #expect(throws: AIError.http(status: 404, message: "The model does not exist")) {
            _ = try await client.transform(prompt: "x", content: "y")
        }
    }

    @Test("empty choices / empty content → emptyResponse")
    func emptyReply() async {
        let client = AIClient(config: config, transport: FakeTransport(body: #"{"choices":[]}"#))
        await #expect(throws: AIError.emptyResponse) { _ = try await client.transform(prompt: "x", content: "y") }
        let blank = AIClient(config: config, transport: FakeTransport(body: #"{"choices":[{"message":{"content":"  \n"}}]}"#))
        await #expect(throws: AIError.emptyResponse) { _ = try await blank.transform(prompt: "x", content: "y") }
    }

    @Test("thinking mode: auto sends nothing, off/on send both vendor knobs")
    func thinkingParams() async throws {
        final class Box: @unchecked Sendable { var body: [String: Any] = [:] }
        for (mode, expectType, expectFlag) in [(AIThinkingMode.auto, nil, nil), (.off, "disabled", false), (.on, "enabled", true)] as [(AIThinkingMode, String?, Bool?)] {
            let box = Box()
            var cfg = config; cfg.thinking = mode
            let client = AIClient(config: cfg, transport: FakeTransport(body: Self.okBody) {
                box.body = (try? JSONSerialization.jsonObject(with: $0.httpBody!) as? [String: Any]) ?? [:]
            })
            _ = try await client.transform(prompt: "x", content: "y")
            #expect((box.body["thinking"] as? [String: String])?["type"] == expectType)
            #expect(box.body["enable_thinking"] as? Bool == expectFlag)
        }
    }

    @Test("reasoning-only reply (thinking ate the budget) is reported as such")
    func reasoningOnly() async {
        let body = #"{"choices":[{"finish_reason":"length","message":{"content":"","reasoning_content":"The user wants"}}]}"#
        let client = AIClient(config: config, transport: FakeTransport(body: body))
        await #expect(throws: AIError.reasoningOnly) { _ = try await client.transform(prompt: "x", content: "y") }
    }

    @Test("inline <think> blocks are stripped from the reply")
    func thinkStripped() async throws {
        let body = #"{"choices":[{"message":{"content":"<think>hmm\nthinking</think>\nHello"}}]}"#
        let client = AIClient(config: config, transport: FakeTransport(body: body))
        #expect(try await client.transform(prompt: "x", content: "y") == "Hello")
        #expect(AIClient.stripThinking("no tags") == "no tags")
        #expect(AIClient.stripThinking("<think>unterminated") == "")
    }

    @Test("stripFences leaves non-fenced text and inner fences alone")
    func fences() {
        #expect(AIClient.stripFences("plain") == "plain")
        #expect(AIClient.stripFences("```\ncode\n```") == "code")
        #expect(AIClient.stripFences("```swift\nlet a = 1\n```") == "let a = 1")
        #expect(AIClient.stripFences("see ```x``` here") == "see ```x``` here")
    }

    // MARK: - Guard

    @Test("send guard: sensitive, blocklisted app, and oversize content are refused")
    func sendGuard() {
        #expect(throws: AIError.sensitiveContent) {
            try AITransformGuard.check(content: "x", isSensitive: true, sourceAppBundleID: nil, blockedBundleIDs: [])
        }
        #expect(throws: AIError.blockedSourceApp) {
            try AITransformGuard.check(content: "x", isSensitive: false, sourceAppBundleID: "com.agilebits.onepassword7", blockedBundleIDs: ["com.agilebits.onepassword7"])
        }
        #expect(throws: AIError.contentTooLong(limit: 10)) {
            try AITransformGuard.check(content: String(repeating: "a", count: 11), isSensitive: false, sourceAppBundleID: nil, blockedBundleIDs: [], limit: 10)
        }
        #expect(throws: Never.self) {
            try AITransformGuard.check(content: "fine", isSensitive: false, sourceAppBundleID: "com.apple.TextEdit", blockedBundleIDs: [])
        }
    }

    // MARK: - Executor AI path

    @Test("executor runs aiTransform through the async path and honours the output mode")
    @MainActor
    func executorAIPath() async throws {
        ActionExecutor.showsToast = false
        let schema = Schema([ClipItem.self, SmartGroup.self, AutomationRule.self])
        let context = ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)))
        let item = ClipItem(content: "你好", contentType: .text)
        context.insert(item)
        let rule = AutomationRule(name: "t", triggerMode: .manual, actions: [.aiTransform(prompt: "Translate to English"), .pin])
        rule.outputMode = .newItem

        ActionExecutor.aiClientOverride = AIClient(config: config, transport: FakeTransport(body: Self.okBody))
        defer { ActionExecutor.aiClientOverride = nil }
        ActionExecutor.apply(rule, to: [item], host: PlainActionHost(source: .quickPanel), context: context)

        // The async path is a detached task; poll briefly.
        for _ in 0..<50 {
            if (try context.fetch(FetchDescriptor<ClipItem>())).count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let all = try context.fetch(FetchDescriptor<ClipItem>())
        #expect(all.count == 2)
        #expect(item.content == "你好")
        let created = try #require(all.first { $0 !== item })
        #expect(created.content == "Hello, world")
        #expect(created.isPinned)
        #expect(ActionExecutor.inFlightItemIDs.isEmpty)
    }

    @Test("per-action overrides beat the global config; nil follows global")
    @MainActor
    func executorOverrides() async throws {
        ActionExecutor.showsToast = false
        let schema = Schema([ClipItem.self, SmartGroup.self, AutomationRule.self])
        let context = ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)))
        let item = ClipItem(content: "你好", contentType: .text)
        context.insert(item)
        let rule = AutomationRule(name: "t", triggerMode: .manual,
                                  actions: [.aiTransform(prompt: "x", thinking: .off, temperature: 0.9, timeoutSeconds: nil)])
        final class Box: @unchecked Sendable { var body: [String: Any] = [:]; var timeout: Double = 0 }
        let box = Box()
        ActionExecutor.aiClientOverride = AIClient(config: config, transport: FakeTransport(body: Self.okBody) {
            box.body = (try? JSONSerialization.jsonObject(with: $0.httpBody!) as? [String: Any]) ?? [:]
            box.timeout = $0.timeoutInterval
        })
        defer { ActionExecutor.aiClientOverride = nil }
        ActionExecutor.apply(rule, to: [item], host: PlainActionHost(source: .quickPanel), context: context)
        for _ in 0..<50 where box.body.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect((box.body["temperature"] as? Double).map { abs($0 - 0.9) < 0.001 } == true)
        #expect((box.body["thinking"] as? [String: String])?["type"] == "disabled")
        #expect(box.timeout == 30)   // nil → the global (test config) timeout
    }

    @Test("old aiTransform JSON without override keys still decodes")
    func aiTransformLegacyDecode() {
        let rule = AutomationRule(name: "t")
        rule.actionsData = Data(#"[{"aiTransform":{"prompt":"x"}}]"#.utf8)
        #expect(rule.actions == [.aiTransform(prompt: "x")])
    }

    @Test("executor leaves the clip untouched when the provider fails")
    @MainActor
    func executorAIFailure() async throws {
        ActionExecutor.showsToast = false
        let schema = Schema([ClipItem.self, SmartGroup.self, AutomationRule.self])
        let context = ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)))
        let item = ClipItem(content: "你好", contentType: .text)
        context.insert(item)
        let rule = AutomationRule(name: "t", triggerMode: .manual, actions: [.aiTransform(prompt: "x")])

        ActionExecutor.aiClientOverride = AIClient(config: config, transport: FakeTransport(status: 500, body: "boom"))
        defer { ActionExecutor.aiClientOverride = nil }
        ActionExecutor.apply(rule, to: [item], host: PlainActionHost(source: .quickPanel), context: context)
        try await Task.sleep(for: .milliseconds(200))

        #expect(item.content == "你好")
        #expect(try context.fetch(FetchDescriptor<ClipItem>()).count == 1)
        #expect(ActionExecutor.inFlightItemIDs.isEmpty)
    }

    @Test("aiTransform descriptors: async, network, manual-only, text-only")
    func descriptors() {
        let a = RuleAction.aiTransform(prompt: "p")
        #expect(a.isAsync)
        #expect(a.kind == .transform)
        #expect(a.inputKind == .text)
        #expect(a.requiresManualTrigger)
        #expect(a.requiredContext.contains(.network))
    }
}
