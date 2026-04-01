import Foundation
import Testing
@testable import PasteMemo

@Suite("PasteMemo Tests")
struct PasteMemoTests {
    @Test("Detect text content type")
    @MainActor func detectText() {
        let result = ClipboardManager.shared.detectContentType("Hello world")
        #expect(result.type == .text)
    }

    @Test("Detect link content type")
    @MainActor func detectLink() {
        let result = ClipboardManager.shared.detectContentType("https://github.com")
        #expect(result.type == .link)
    }

    @Test("Detect color content type")
    @MainActor func detectColor() {
        let result = ClipboardManager.shared.detectContentType("#FF5733")
        #expect(result.type == .color)
    }

    @Test("Detect code content type")
    @MainActor func detectCode() {
        let code = """
        import Foundation
        func hello() {
            print("world")
        }
        """
        let result = ClipboardManager.shared.detectContentType(code)
        #expect(result.type == .code)
    }
}

@Suite("RelayItem Tests")
struct RelayItemTests {
    @Test("Init sets pending state")
    func initState() {
        let item = RelayItem(content: "test")
        #expect(item.state == .pending)
        #expect(item.content == "test")
        #expect(!item.id.uuidString.isEmpty)
    }
}

@Suite("RelaySplitter Tests")
struct RelaySplitterTests {
    @Test("Split by newline")
    func splitNewline() {
        let result = RelaySplitter.split("A\nB\nC", by: .newline)
        #expect(result == ["A", "B", "C"])
    }

    @Test("Split by comma")
    func splitComma() {
        let result = RelaySplitter.split("张三,李四,王五", by: .comma)
        #expect(result == ["张三", "李四", "王五"])
    }

    @Test("Split by Chinese comma")
    func splitChineseComma() {
        let result = RelaySplitter.split("张三、李四、王五", by: .chineseComma)
        #expect(result == ["张三", "李四", "王五"])
    }

    @Test("Split by custom delimiter")
    func splitCustom() {
        let result = RelaySplitter.split("A|B|C", by: .custom("|"))
        #expect(result == ["A", "B", "C"])
    }

    @Test("Filter empty strings from consecutive delimiters")
    func filterEmpty() {
        let result = RelaySplitter.split("A,,B,,C", by: .comma)
        #expect(result == ["A", "B", "C"])
    }

    @Test("Trim whitespace from results")
    func trimWhitespace() {
        let result = RelaySplitter.split("A , B , C", by: .comma)
        #expect(result == ["A", "B", "C"])
    }

    @Test("Return nil when delimiter not found")
    func noDelimiter() {
        let result = RelaySplitter.split("Hello World", by: .comma)
        #expect(result == nil)
    }

    @Test("Return nil for single result")
    func singleResult() {
        let result = RelaySplitter.split("Hello,", by: .comma)
        #expect(result == nil)
    }
}

@Suite("RelayManager Tests")
struct RelayManagerTests {
    @Test("Enqueue items")
    @MainActor func enqueue() {
        let manager = makeManager()
        manager.enqueue(texts: ["A", "B", "C"])
        #expect(manager.items.count == 3)
        #expect(manager.items[0].state == .current)
        #expect(manager.items[1].state == .pending)
    }

    @Test("Advance moves pointer forward")
    @MainActor func advance() {
        let manager = makeManager()
        manager.enqueue(texts: ["A", "B", "C"])
        let item = manager.advance()
        #expect(item?.content == "A")
        #expect(manager.items[0].state == .done)
        #expect(manager.items[1].state == .current)
        #expect(manager.currentIndex == 1)
    }

    @Test("Advance returns nil when exhausted")
    @MainActor func advanceExhausted() {
        let manager = makeManager()
        manager.enqueue(texts: ["A"])
        _ = manager.advance()
        let item = manager.advance()
        #expect(item == nil)
        #expect(manager.isQueueExhausted)
    }

    @Test("Skip marks current as skipped")
    @MainActor func skip() {
        let manager = makeManager()
        manager.enqueue(texts: ["A", "B"])
        manager.skip()
        #expect(manager.items[0].state == .skipped)
        #expect(manager.items[1].state == .current)
    }

    @Test("Rollback moves pointer backward")
    @MainActor func rollback() {
        let manager = makeManager()
        manager.enqueue(texts: ["A", "B", "C"])
        _ = manager.advance()
        manager.rollback()
        #expect(manager.currentIndex == 0)
        #expect(manager.items[0].state == .current)
    }

    @Test("Rollback resets skipped items")
    @MainActor func rollbackSkipped() {
        let manager = makeManager()
        manager.enqueue(texts: ["A", "B", "C"])
        manager.skip()
        manager.rollback()
        #expect(manager.items[0].state == .current)
    }

    @Test("Delete removes item and adjusts pointer")
    @MainActor func deleteItem() {
        let manager = makeManager()
        manager.enqueue(texts: ["A", "B", "C"])
        _ = manager.advance()
        manager.deleteItem(at: 0)
        #expect(manager.items.count == 2)
        #expect(manager.currentIndex == 0)
        #expect(manager.items[0].state == .current)
        #expect(manager.items[0].content == "B")
    }

    @Test("Move reorders items")
    @MainActor func moveItem() {
        let manager = makeManager()
        manager.enqueue(texts: ["A", "B", "C"])
        manager.moveItem(from: Foundation.IndexSet(integer: 2), to: 0)
        #expect(manager.items[0].content == "C")
    }

    @Test("Split replaces item with multiple")
    @MainActor func splitItem() {
        let manager = makeManager()
        manager.enqueue(texts: ["张三,李四,王五"])
        let success = manager.splitItem(at: 0, by: .comma)
        #expect(success)
        #expect(manager.items.count == 3)
        #expect(manager.items[0].content == "张三")
    }

    @Test("Progress string")
    @MainActor func progress() {
        let manager = makeManager()
        manager.enqueue(texts: ["A", "B", "C"])
        _ = manager.advance()
        #expect(manager.progressText == "1/3")
    }
}

// RelayManager.shared is singleton, so create fresh instances for tests
@MainActor
private func makeManager() -> RelayManager {
    let manager = RelayManager.shared
    manager.deactivate()
    manager.items.removeAll()
    manager.currentIndex = 0
    return manager
}
