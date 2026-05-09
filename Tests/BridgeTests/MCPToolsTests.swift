import XCTest
import SwiftData
@testable import PasteMemo

@MainActor
final class MCPToolsTests: XCTestCase {

    func testGetCurrentReturnsLatestNonSensitiveItem() async throws {
        let container = SampleClips.makeContainer()
        _ = SampleClips.seed(in: container.mainContext)

        let tool = GetCurrentTool()
        let guardLayer = PrivacyGuard(allowSensitive: false, sourceAppBlocklist: [])
        let result = try await tool.call(params: nil, container: container, guardLayer: guardLayer)

        // result 是 MCP 标准 { content: [{ type: "text", text: <json> }] }
        guard case .object(let outer) = result,
              case .array(let arr) = outer["content"]!,
              case .object(let first) = arr.first!,
              case .string(let text) = first["text"]!
        else { XCTFail("Bad shape"); return }

        // 解析 inner JSON
        let inner = try JSONDecoder().decode(GetCurrentTool.Output.self,
                                             from: text.data(using: .utf8)!)
        XCTAssertEqual(inner.content, "Hello world") // 最新非敏感
        XCTAssertEqual(inner.content_type, "text")
    }

    func testSearchByQueryReturnsMatchingPreviews() async throws {
        let container = SampleClips.makeContainer()
        _ = SampleClips.seed(in: container.mainContext)

        let tool = SearchHistoryTool()
        let params: JSONValue = .object([
            "query": .string("Hello"),
            "limit": .number(10)
        ])
        let guardLayer = PrivacyGuard(allowSensitive: false, sourceAppBlocklist: [])
        let result = try await tool.call(params: params, container: container, guardLayer: guardLayer)

        guard case .object(let outer) = result,
              case .array(let arr) = outer["content"]!,
              case .object(let first) = arr.first!,
              case .string(let text) = first["text"]!
        else { XCTFail("Bad shape"); return }
        let items = try JSONDecoder().decode([SearchHistoryTool.OutputItem].self,
                                              from: text.data(using: .utf8)!)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Hello world")
    }

    func testSearchEmptyQueryReturnsRecent() async throws {
        let container = SampleClips.makeContainer()
        _ = SampleClips.seed(in: container.mainContext)

        let tool = SearchHistoryTool()
        let result = try await tool.call(params: nil, container: container,
                                          guardLayer: PrivacyGuard(allowSensitive: false, sourceAppBlocklist: []))
        guard case .object(let outer) = result,
              case .array(let arr) = outer["content"]!,
              case .object(let first) = arr.first!,
              case .string(let text) = first["text"]!
        else { XCTFail("Bad shape"); return }
        let items = try JSONDecoder().decode([SearchHistoryTool.OutputItem].self,
                                              from: text.data(using: .utf8)!)
        // 5 条样本 - 1 敏感（默认过滤）= 4
        XCTAssertEqual(items.count, 4)
    }

    func testSearchPreviewTruncatedAt200() async throws {
        let container = SampleClips.makeContainer()
        _ = SampleClips.seed(in: container.mainContext)

        let tool = SearchHistoryTool()
        let result = try await tool.call(
            params: .object(["query": .string("AAAA")]),
            container: container,
            guardLayer: PrivacyGuard(allowSensitive: false, sourceAppBlocklist: [])
        )
        guard case .object(let outer) = result,
              case .array(let arr) = outer["content"]!,
              case .object(let first) = arr.first!,
              case .string(let text) = first["text"]!
        else { XCTFail("Bad shape"); return }
        let items = try JSONDecoder().decode([SearchHistoryTool.OutputItem].self,
                                              from: text.data(using: .utf8)!)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].content_preview.count, 200)
    }

    func testGetItemByIDReturnsFullContent() async throws {
        let container = SampleClips.makeContainer()
        let items = SampleClips.seed(in: container.mainContext)
        let target = items[0] // "Hello world"

        let tool = GetItemTool()
        let result = try await tool.call(
            params: .object(["id": .string(target.itemID)]),
            container: container,
            guardLayer: PrivacyGuard(allowSensitive: false, sourceAppBlocklist: [])
        )
        guard case .object(let outer) = result,
              case .array(let arr) = outer["content"]!,
              case .object(let first) = arr.first!,
              case .string(let text) = first["text"]!
        else { XCTFail("Bad shape"); return }
        let inner = try JSONDecoder().decode(GetItemTool.Output.self,
                                             from: text.data(using: .utf8)!)
        XCTAssertEqual(inner.content, "Hello world")
    }

    func testGetItemBlockedByPrivacyReturnsError() async throws {
        let container = SampleClips.makeContainer()
        let items = SampleClips.seed(in: container.mainContext)
        let sensitive = items[1] // 敏感项

        let tool = GetItemTool()
        do {
            _ = try await tool.call(
                params: .object(["id": .string(sensitive.itemID)]),
                container: container,
                guardLayer: PrivacyGuard(allowSensitive: false, sourceAppBlocklist: [])
            )
            XCTFail("Should have thrown")
        } catch {
            // 期望抛错(item 被 PrivacyGuard 滤掉,从 Agent 角度等同 "not found")
        }
    }

    func testListRecentAppsAggregatesBySourceApp() async throws {
        let container = SampleClips.makeContainer()
        _ = SampleClips.seed(in: container.mainContext)

        let tool = ListRecentAppsTool()
        let result = try await tool.call(
            params: nil,
            container: container,
            guardLayer: PrivacyGuard(allowSensitive: false, sourceAppBlocklist: [])
        )
        guard case .object(let outer) = result,
              case .array(let arr) = outer["content"]!,
              case .object(let first) = arr.first!,
              case .string(let text) = first["text"]!
        else { XCTFail("Bad shape"); return }
        let apps = try JSONDecoder().decode([ListRecentAppsTool.OutputItem].self,
                                             from: text.data(using: .utf8)!)
        // 5 样本去掉 1 敏感(1Password) = 4 items 来自 4 不同源 App
        XCTAssertEqual(apps.count, 4)
    }
}
