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
}
