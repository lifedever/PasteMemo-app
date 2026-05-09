import XCTest
import SwiftData
@testable import PasteMemo

@MainActor
final class MCPRouterTests: XCTestCase {

    func testInitializeReturnsServerInfo() async throws {
        let router = MCPRequestRouter(container: SampleClips.makeContainer())
        let req = JSONRPCRequest(jsonrpc: "2.0", id: .number(1),
                                 method: "initialize", params: nil)
        let resp = await router.handle(req)
        XCTAssertNil(resp.error)
        guard case .object(let r) = resp.result!,
              case .object(let serverInfo) = r["serverInfo"]!,
              case .string(let name) = serverInfo["name"]!
        else { XCTFail("Bad shape"); return }
        XCTAssertEqual(name, "pastememo")
    }

    func testToolsListReturnsAll5Tools() async throws {
        let router = MCPRequestRouter(container: SampleClips.makeContainer())
        let req = JSONRPCRequest(jsonrpc: "2.0", id: .number(2),
                                 method: "tools/list", params: nil)
        let resp = await router.handle(req)
        XCTAssertNil(resp.error)
        guard case .object(let r) = resp.result!,
              case .array(let tools) = r["tools"]!
        else { XCTFail("Bad shape"); return }
        XCTAssertEqual(tools.count, 5)
    }

    func testToolsCallDispatchesToCorrectTool() async throws {
        let container = SampleClips.makeContainer()
        _ = SampleClips.seed(in: container.mainContext)
        let router = MCPRequestRouter(container: container)

        let req = JSONRPCRequest(jsonrpc: "2.0", id: .number(3),
                                 method: "tools/call",
                                 params: .object([
                                    "name": .string("clipboard_get_current"),
                                    "arguments": .object([:])
                                 ]))
        let resp = await router.handle(req)
        XCTAssertNil(resp.error, "Got error: \(String(describing: resp.error))")
    }

    func testUnknownMethodReturnsMethodNotFound() async throws {
        let router = MCPRequestRouter(container: SampleClips.makeContainer())
        let req = JSONRPCRequest(jsonrpc: "2.0", id: .number(99),
                                 method: "foo/bar", params: nil)
        let resp = await router.handle(req)
        XCTAssertNotNil(resp.error)
        XCTAssertEqual(resp.error?.code, -32601)
    }
}
