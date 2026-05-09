import Foundation
#if canImport(Darwin)
import Darwin
#endif

// pastememo-mcp: stdio ⇄ Unix socket 转发
// 即使 socket 不存在(App 没启动),也要返回合法 MCP 响应,
// 让 Agent 不报启动失败,只是看到 0 个工具。

let socketPath: String = {
    // ~/Library/Application Support/com.lifedever.pastememo[.dev]/mcp.sock
    // 优先生产版,然后 dev 版,最后默认生产路径
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    for bid in ["com.lifedever.pastememo", "com.lifedever.pastememo.dev"] {
        let p = base.appendingPathComponent(bid).appendingPathComponent("mcp.sock").path
        if FileManager.default.fileExists(atPath: p) {
            return p
        }
    }
    return base.appendingPathComponent("com.lifedever.pastememo/mcp.sock").path
}()

func connectSocket() -> Int32? {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
            _ = pathBytes.withUnsafeBytes { src in
                memcpy(dest, src.baseAddress!, min(pathBytes.count, 104))
            }
        }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let r = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
            Darwin.connect(fd, sap, size)
        }
    }
    if r != 0 {
        Darwin.close(fd)
        return nil
    }
    return fd
}

// MARK: - Offline 模式: 仍能处理 initialize / tools/list

func sendOfflineResponse(line: String) {
    guard let data = line.data(using: .utf8),
          let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = req["method"] as? String else {
        return
    }
    let id = req["id"]
    var result: [String: Any] = [:]
    switch method {
    case "initialize":
        result = [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [:]],
            "serverInfo": [
                "name": "pastememo (offline)",
                "version": "1.0.0"
            ]
        ]
    case "tools/list":
        result = ["tools": []]
    default:
        // 其他方法:返回 error,但保持合法 JSON-RPC
        let resp: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": -32000, "message": "PasteMemo is not running. Open the app to enable tools."]
        ]
        if let respData = try? JSONSerialization.data(withJSONObject: resp) {
            FileHandle.standardOutput.write(respData)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
        return
    }
    let resp: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id ?? NSNull(),
        "result": result
    ]
    if let respData = try? JSONSerialization.data(withJSONObject: resp) {
        FileHandle.standardOutput.write(respData)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

// MARK: - 主循环

let socketFD = connectSocket()

if let fd = socketFD {
    // 在线模式: 双向转发
    let stdinThread = Thread {
        let stdin = FileHandle.standardInput
        while true {
            let data = stdin.availableData
            if data.isEmpty { exit(0) }
            data.withUnsafeBytes { buf in
                _ = Darwin.send(fd, buf.baseAddress, buf.count, 0)
            }
        }
    }
    stdinThread.start()

    let stdout = FileHandle.standardOutput
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = Darwin.recv(fd, &buf, buf.count, 0)
        if n <= 0 { exit(0) }
        stdout.write(Data(bytes: buf, count: n))
    }
} else {
    // 离线模式: 行解析自己回
    let stdin = FileHandle.standardInput
    var buffer = Data()
    while true {
        let chunk = stdin.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: 0..<nl)
            buffer.removeSubrange(0...nl)
            if let s = String(data: line, encoding: .utf8), !s.isEmpty {
                sendOfflineResponse(line: s)
            }
        }
    }
}
