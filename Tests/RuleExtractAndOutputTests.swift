import AppKit
import Foundation
import SwiftData
import Testing
@testable import PasteMemo

/// Actions that used to exist only as ⌘K rows (extract / OCR / open / Relay / delete /
/// sound) and the two outputs that leave PasteMemo (save to folder, webhook).
@Suite("Rule extract actions, side effects and outputs", .serialized)
@MainActor
struct RuleExtractAndOutputTests {

    private struct RecordingTransport: AITransport {
        let status: Int
        let onRequest: @Sendable (URLRequest) -> Void
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            onRequest(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([ClipItem.self, SmartGroup.self, AutomationRule.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: config))
    }

    private func makeRule(_ actions: [RuleAction], output: RuleOutputMode = .replaceItem, param: String = "") -> AutomationRule {
        let rule = AutomationRule(name: "t", triggerMode: .manual, actions: actions)
        rule.outputMode = output
        rule.outputParam = param
        return rule
    }

    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pm-rule-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init() {
        ActionExecutor.showsToast = false
        ActionExecutor.performsSideEffects = false
    }

    // MARK: - Extract transforms

    @Test("convertColor reformats a color and leaves other text alone")
    func convertColor() {
        #expect(RuleAction.convertColor(format: "RGB").execute(on: " #FF8000 ") == "rgb(255, 128, 0)")
        #expect(RuleAction.convertColor(format: "HEX").execute(on: "rgb(0, 0, 255)") == "#0000FF")
        #expect(RuleAction.convertColor(format: "HEX").execute(on: "not a color") == "not a color")
    }

    @Test("extractVerificationCode keeps only the code; no code → unchanged")
    func extractCode() {
        #expect(RuleAction.extractVerificationCode.execute(on: "【某某】您的验证码是 482913，5 分钟内有效。") == "482913")
        let plain = "明天下午三点开会"
        #expect(RuleAction.extractVerificationCode.execute(on: plain) == plain)
    }

    @Test("extractLinks keeps every http(s) link, one per line; bare link and no-link cases")
    func extractLinks() {
        let text = "看这个 https://example.com/a 还有 http://foo.org/b?x=1 和 https://example.com/a 以及 readme.md"
        #expect(RuleAction.extractLinks.execute(on: text) == "https://example.com/a\nhttp://foo.org/b?x=1")
        #expect(RuleAction.extractLinks.execute(on: "https://example.com") == "https://example.com")
        #expect(RuleAction.extractLinks.execute(on: "没有链接") == "没有链接")
    }

    // MARK: - Descriptors

    @Test("descriptors: OCR reads images and is async; open / Relay / delete are manual-only; sound isn't")
    func descriptors() {
        #expect(RuleAction.runOCR.inputKind == .image)
        #expect(RuleAction.runOCR.isAsync)
        #expect(RuleAction.runOCR.requiresManualTrigger)
        for action in [RuleAction.openLink, .openInPreview, .showInFinder, .addToRelay, .splitToRelay(delimiter: ","), .deleteItem] {
            #expect(action.kind == .sideEffect)
            #expect(action.requiresManualTrigger)
        }
        #expect(RuleAction.showInFinder.inputKind == .file)
        #expect(!RuleAction.playSound(name: "system:Glass").requiresManualTrigger)
        #expect(!RuleAction.convertColor(format: "HEX").requiresManualTrigger)
    }

    @Test("output-only rules show in ⌘K: save-to-folder for anything, webhook for text")
    func matchesOutputOnly() {
        let image = ClipItem(content: "[Image]", contentType: .image)
        let text = ClipItem(content: "hi", contentType: .text)
        let save = makeRule([], output: .saveToFile, param: "/tmp")
        let hook = makeRule([], output: .postWebhook, param: "https://x.example")
        #expect(save.matches(item: image))
        #expect(hook.matches(item: text))
        #expect(!hook.matches(item: image))
        #expect(!makeRule([]).matches(item: text))
    }

    @Test("an OCR + AI rule is offered on images; an AI-only rule still isn't")
    func matchesOCRChain() {
        let image = ClipItem(content: "[Image]", contentType: .image)
        #expect(AutomationRule(name: "t", actions: [.runOCR, .aiTransform(prompt: "p")]).matches(item: image))
        #expect(!AutomationRule(name: "t", actions: [.aiTransform(prompt: "p")]).matches(item: image))
    }

    // MARK: - Side effects

    @Test("openLink opens the processed text as a link, else the first http(s) link; other schemes never")
    func openLink() throws {
        let context = try makeContext()
        let search = ClipItem(content: "swift testing", contentType: .text)
        let mixed = ClipItem(content: "文档在 https://example.com/doc 里", contentType: .text)
        let unsafe = ClipItem(content: "javascript:alert(1)", contentType: .text)
        context.insert(search); context.insert(mixed); context.insert(unsafe)

        let rule = makeRule([.urlEncode, .addPrefix(text: "https://www.google.com/search?q="), .openLink])
        ActionExecutor.apply(rule, to: [search], host: PlainActionHost(source: .quickPanel), context: context)
        #expect(ActionExecutor.lastSideEffects.links.map(\.absoluteString) == ["https://www.google.com/search?q=swift%20testing"])

        ActionExecutor.apply(makeRule([.openLink]), to: [mixed], host: PlainActionHost(source: .quickPanel), context: context)
        #expect(ActionExecutor.lastSideEffects.links.map(\.absoluteString) == ["https://example.com/doc"])

        ActionExecutor.apply(makeRule([.openLink]), to: [unsafe], host: PlainActionHost(source: .quickPanel), context: context)
        #expect(ActionExecutor.lastSideEffects.links.isEmpty)
    }

    @Test("openLink never turns a bare word into https://word")
    func openLinkBareWord() {
        #expect(ActionExecutor.linkToOpen(in: "hello") == nil)
        #expect(ActionExecutor.linkToOpen(in: "README") == nil)
        #expect(ActionExecutor.linkToOpen(in: "example.com/docs")?.host == "example.com")
        #expect(ActionExecutor.linkToOpen(in: " https://example.com/a?b=1 ")?.absoluteString == "https://example.com/a?b=1")
    }

    @Test("saveToFile on an image without bytes fails instead of writing the placeholder")
    func saveImageWithoutBytes() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = ClipItem(content: "[Image]", contentType: .image)
        #expect(RuleOutputDelivery.save(text: "[Image]", of: image, asText: false, into: folder) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test("Relay actions queue the processed text; split drops blank pieces")
    func relay() throws {
        let context = try makeContext()
        let item = ClipItem(content: "a, b,, c", contentType: .text)
        context.insert(item)

        ActionExecutor.apply(makeRule([.uppercased, .splitToRelay(delimiter: ",")], output: .clipboard),
                             to: [item], host: PlainActionHost(source: .mainWindow), context: context)
        #expect(ActionExecutor.lastSideEffects.relayTexts == ["A", "B", "C"])
        #expect(ActionExecutor.split("x\n\n y \n", by: "") == ["x", "y"])

        ActionExecutor.apply(makeRule([.addToRelay], output: .clipboard),
                             to: [item], host: PlainActionHost(source: .mainWindow), context: context)
        #expect(ActionExecutor.lastSideEffects.relayTexts == ["a, b,, c"])
    }

    @Test("deleteItem and playSound are collected; leaving actions dismiss the panel")
    func deleteAndSound() throws {
        let context = try makeContext()
        let item = ClipItem(content: "x", contentType: .text)
        context.insert(item)
        final class Host: ActionHost {
            let source = ExecutionSource.quickPanel
            let targetApp: NSRunningApplication? = nil
            var dismissed = 0
            func dismissPanel() { dismissed += 1 }
        }
        let host = Host()

        ActionExecutor.apply(makeRule([.deleteItem, .playSound(name: "system:Glass")]), to: [item], host: host, context: context)
        #expect(ActionExecutor.lastSideEffects.deletedItemIDs == [item.itemID])
        #expect(ActionExecutor.lastSideEffects.sound == "system:Glass")
        #expect(host.dismissed == 0)

        let link = ClipItem(content: "https://example.com", contentType: .link)
        context.insert(link)
        ActionExecutor.apply(makeRule([.openLink]), to: [link], host: host, context: context)
        #expect(host.dismissed == 1)
    }

    // MARK: - OCR chain

    @Test("OCR → transform: the image stays, the recognised text becomes its own clip")
    func ocrChain() async throws {
        let context = try makeContext()
        let image = ClipItem(content: "[Image]", contentType: .image, imageData: Data([0x89, 0x50]))
        context.insert(image)
        ActionExecutor.ocrOverride = { _ in "hello world" }
        defer { ActionExecutor.ocrOverride = nil }

        ActionExecutor.apply(makeRule([.runOCR, .uppercased]), to: [image], host: PlainActionHost(source: .quickPanel), context: context)
        try await Task.sleep(for: .milliseconds(200))

        let all = try context.fetch(FetchDescriptor<ClipItem>())
        #expect(all.count == 2)
        #expect(image.content == "[Image]")
        let text = try #require(all.first { $0 !== image })
        #expect(text.content == "HELLO WORLD")
        #expect(text.contentType.isMergeable)
    }

    @Test("OCR that finds nothing changes nothing")
    func ocrEmpty() async throws {
        let context = try makeContext()
        let image = ClipItem(content: "[Image]", contentType: .image, imageData: Data([0x89, 0x50]))
        context.insert(image)
        ActionExecutor.ocrOverride = { _ in nil }
        defer { ActionExecutor.ocrOverride = nil }

        ActionExecutor.apply(makeRule([.runOCR], output: .newItem), to: [image], host: PlainActionHost(source: .quickPanel), context: context)
        try await Task.sleep(for: .milliseconds(200))

        #expect(try context.fetch(FetchDescriptor<ClipItem>()).count == 1)
        #expect(ActionExecutor.inFlightItemIDs.isEmpty)
    }

    // MARK: - Save to folder

    @Test("saveToFile writes the processed text and leaves the clip untouched")
    func saveToFile() throws {
        let context = try makeContext()
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = ClipItem(content: "Hello", contentType: .text)
        context.insert(item)

        ActionExecutor.apply(makeRule([.uppercased], output: .saveToFile, param: folder.path),
                             to: [item], host: PlainActionHost(source: .mainWindow), context: context)

        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect(try String(contentsOf: try #require(files.first), encoding: .utf8) == "HELLO")
        #expect(item.content == "Hello")
    }

    @Test("saveToFile with a vanished folder writes nothing and doesn't crash")
    func saveToMissingFolder() throws {
        let context = try makeContext()
        let item = ClipItem(content: "Hello", contentType: .text)
        context.insert(item)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("pm-missing-\(UUID().uuidString)").path
        ActionExecutor.apply(makeRule([], output: .saveToFile, param: missing),
                             to: [item], host: PlainActionHost(source: .mainWindow), context: context)
        #expect(!FileManager.default.fileExists(atPath: missing))
        #expect(item.content == "Hello")
    }

    @Test("folder / URL validation")
    func validation() {
        #expect(RuleOutputDelivery.folderURL(from: NSTemporaryDirectory()) != nil)
        #expect(RuleOutputDelivery.folderURL(from: "") == nil)
        #expect(RuleOutputDelivery.webhookURL(from: " https://hooks.example.com/x ") != nil)
        #expect(RuleOutputDelivery.webhookURL(from: "http://localhost:5678/webhook") != nil)
        #expect(RuleOutputDelivery.webhookURL(from: "ftp://example.com") == nil)
        #expect(RuleOutputDelivery.webhookURL(from: "example.com/hook") == nil)
    }

    // MARK: - Webhook

    @Test("postWebhook POSTs the processed text as JSON; sensitive clips are never sent")
    func webhook() async throws {
        let context = try makeContext()
        let normal = ClipItem(content: "hi", contentType: .text, sourceAppBundleID: "com.apple.Safari")
        let secret = ClipItem(content: "hunter2", contentType: .text)
        secret.isSensitive = true
        context.insert(normal); context.insert(secret)

        let requests = Box<[URLRequest]>([])
        let lock = NSLock()
        RuleOutputDelivery.webhookTransport = RecordingTransport(status: 200) { request in
            lock.withLock { requests.value.append(request) }
        }
        defer { RuleOutputDelivery.webhookTransport = URLSessionTransport() }

        let rule = makeRule([.uppercased], output: .postWebhook, param: "https://hooks.example.com/in")
        ActionExecutor.apply(rule, to: [normal, secret], host: PlainActionHost(source: .mainWindow), context: context)
        try await Task.sleep(for: .milliseconds(200))

        let sent = lock.withLock { requests.value }
        #expect(sent.count == 1)
        let request = try #require(sent.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://hooks.example.com/in")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["content"] as? String == "HI")
        #expect(json["sourceApp"] as? String == "com.apple.Safari")
        #expect(json["rule"] as? String == "t")
        #expect(normal.content == "hi")
    }

    // MARK: - Shortcuts "process text with rule"

    @Test("transformText runs the text transforms in order and ignores everything else")
    func transformText() async throws {
        let actions: [RuleAction] = [
            .runOCR, .trimWhitespace, .toSnakeCase, .pin, .deleteItem, .runShortcut(name: "x"),
            .addPrefix(text: "> "), .openLink,
        ]
        let result = try await ActionExecutor.transformText("  userName  ", with: actions)
        #expect(result == "> user_name")
    }

    // MARK: - Capture path

    @Test("capture: an output-only rule (no actions) still fires and carries its output")
    func captureOutputOnly() throws {
        let context = try makeContext()
        UserDefaults.standard.set(true, forKey: "automationEnabled")
        let rule = AutomationRule(name: "save links", conditions: [.contentType(.link)], actions: [])
        rule.outputMode = .saveToFile
        rule.outputParam = "/tmp"
        context.insert(rule)
        try context.save()

        let result = AutomationEngine.shared.process(
            content: "https://example.com", contentType: .link, sourceApp: nil, context: context
        )
        guard case .applied(let content, _, _, let writeBack, let outputs) = result else {
            Issue.record("expected .applied, got \(result)")
            return
        }
        #expect(content == "https://example.com")
        #expect(!writeBack)
        #expect(outputs == [CaptureOutput(mode: .saveToFile, param: "/tmp", ruleName: "save links")])
    }

    @Test("backup round-trip keeps the output parameter")
    func exportKeepsOutputParam() throws {
        let rule = AutomationRule(name: "hook", actions: [.uppercased])
        rule.outputMode = .postWebhook
        rule.outputParam = "https://hooks.example.com/in"
        let exported = DataPorter.buildSingleExportRule(rule)
        let decoded = try JSONDecoder().decode(ExportRule.self, from: try JSONEncoder().encode(exported))
        #expect(decoded.outputParam == "https://hooks.example.com/in")
        #expect(decoded.outputModeRaw == "postWebhook")
    }
}
