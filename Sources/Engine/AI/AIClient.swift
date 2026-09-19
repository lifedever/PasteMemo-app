import Foundation

struct AIClientConfig: Equatable, Sendable {
    var baseURL: String
    var apiKey: String
    var model: String
    var timeout: Double
    var temperature: Double
    var thinking: AIThinkingMode = .auto
}

enum AIError: Error, Equatable {
    case notConfigured
    case contentTooLong(limit: Int)
    case sensitiveContent
    case blockedSourceApp
    case http(status: Int, message: String)
    case emptyResponse
    /// The reply had reasoning but no answer text (thinking ate the token budget).
    case reasoningOnly
    case timeout
    case network(String)
    case badBaseURL

    /// User-facing text. `L10n` is main-actor bound, so this isn't `LocalizedError`.
    @MainActor var userMessage: String {
        switch self {
        case .notConfigured: L10n.tr("automation.ai.notConfigured")
        case .contentTooLong(let limit): L10n.tr("automation.ai.error.tooLong", limit)
        case .sensitiveContent: L10n.tr("automation.ai.error.sensitive")
        case .blockedSourceApp: L10n.tr("automation.ai.error.blockedApp")
        case .http(let status, let message):
            message.isEmpty ? L10n.tr("automation.ai.error.http", status) : L10n.tr("automation.ai.error.http", status) + ": " + message
        case .emptyResponse: L10n.tr("automation.ai.error.empty")
        case .reasoningOnly: L10n.tr("automation.ai.error.reasoningOnly")
        case .timeout: L10n.tr("automation.ai.error.timeout")
        case .network(let msg): msg
        case .badBaseURL: L10n.tr("automation.ai.error.badBaseURL")
        }
    }
}

/// Injectable transport so the client is testable without a network.
protocol AITransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionTransport: AITransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

/// Minimal OpenAI-compatible chat client. One request, one reply, no streaming — the
/// quick panel is a millisecond-scale interaction, not a chat window.
struct AIClient: Sendable {
    let config: AIClientConfig
    let transport: AITransport

    init(config: AIClientConfig, transport: AITransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    /// Fixed system prompt. The user's prompt only says *what* to do; this keeps the
    /// model from chatting back, wrapping in quotes, or adding explanations.
    static let systemPrompt = """
    You are a text transformation tool inside a clipboard manager. The user gives an \
    instruction and then the text to transform. Apply the instruction to the text and \
    output ONLY the resulting text: no explanations, no preamble, no quotes, no markdown \
    code fences. Preserve the original line breaks unless the instruction says otherwise. \
    If the text is already in the requested form, output it unchanged.
    """

    // MARK: - Public

    func transform(prompt: String, content: String) async throws -> String {
        let user = prompt.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n---\n\n" + content
        let reply = try await complete(messages: [
            ["role": "system", "content": Self.systemPrompt],
            ["role": "user", "content": user],
        ], maxTokens: nil)
        return Self.stripFences(reply)
    }

    /// Round-trip for the settings page. No `max_tokens` cap: a thinking model spends
    /// its first hundred tokens reasoning, and an 8-token cap came back with no answer.
    func testConnection() async throws -> String {
        try await complete(messages: [
            ["role": "user", "content": "Reply with the single word OK."],
        ], maxTokens: nil)
    }

    // MARK: - Request / response

    static func endpointURL(baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        let full = trimmed.hasSuffix("/chat/completions") ? trimmed : trimmed + "/chat/completions"
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    func makeRequest(messages: [[String: String]], maxTokens: Int?) throws -> URLRequest {
        guard let url = Self.endpointURL(baseURL: config.baseURL) else { throw AIError.badBaseURL }
        var body: [String: Any] = [
            "model": config.model,
            "messages": messages,
            "temperature": config.temperature,
            "stream": false,
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }
        switch config.thinking {
        case .auto: break
        case .off:
            body["thinking"] = ["type": "disabled"]
            body["enable_thinking"] = false
        case .on:
            body["thinking"] = ["type": "enabled"]
            body["enable_thinking"] = true
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func complete(messages: [[String: String]], maxTokens: Int?) async throws -> String {
        guard !config.model.isEmpty else { throw AIError.notConfigured }
        let request = try makeRequest(messages: messages, maxTokens: maxTokens)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as URLError where error.code == .timedOut {
            throw AIError.timeout
        } catch {
            throw AIError.network(error.localizedDescription)
        }
        return try Self.parseReply(data: data, response: response)
    }

    static func parseReply(data: Data, response: URLResponse) throws -> String {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw AIError.http(status: status, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AIError.emptyResponse
        }
        // Standard: content is a string. Some gateways return an array of parts.
        var text = ""
        if let s = message["content"] as? String {
            text = s
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined()
        }
        let trimmed = stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let reasoning = (message["reasoning_content"] as? String) ?? ""
            throw reasoning.isEmpty ? AIError.emptyResponse : AIError.reasoningOnly
        }
        return trimmed
    }

    /// Some servers inline the reasoning as `<think>…</think>` in front of the answer.
    static func stripThinking(_ text: String) -> String {
        guard text.contains("<think>") else { return text }
        var out = text
        while let open = out.range(of: "<think>") {
            guard let close = out.range(of: "</think>", range: open.upperBound..<out.endIndex) else {
                out.removeSubrange(open.lowerBound..<out.endIndex)
                break
            }
            out.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return out
    }

    /// Models sometimes wrap the whole answer in ``` fences despite the system prompt.
    static func stripFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```"), s.hasSuffix("```"), s.count > 6 else { return s }
        s.removeFirst(3)
        s.removeLast(3)
        // Drop an optional language tag on the opening fence line.
        if let nl = s.firstIndex(of: "\n") {
            let firstLine = s[s.startIndex..<nl]
            if !firstLine.contains(" ") && firstLine.count <= 20 { s = String(s[s.index(after: nl)...]) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Send guard

/// Hard boundary for what may leave the machine. Checked right before an `aiTransform`
/// runs, independent of the model or prompt.
enum AITransformGuard {
    static func check(content: String, isSensitive: Bool, sourceAppBundleID: String?,
                      blockedBundleIDs: Set<String>, limit: Int = AIProviderSettings.maxContentLength) throws {
        if isSensitive { throw AIError.sensitiveContent }
        if let bid = sourceAppBundleID, blockedBundleIDs.contains(bid) { throw AIError.blockedSourceApp }
        if content.count > limit { throw AIError.contentTooLong(limit: limit) }
    }
}
