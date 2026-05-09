import Foundation
import Darwin
import Dispatch
import SwiftData
import OSLog

private let log = Logger(subsystem: "com.lifedever.pastememo", category: "MCPSocketServer")

@MainActor
final class MCPSocketServer {
    static let shared = MCPSocketServer()

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var router: MCPRequestRouter?
    private var socketPath: String?

    private init() {}

    func start(container: ModelContainer) {
        guard listenFD < 0 else {
            log.info("Already running")
            return
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lifedever.pastememo"
        let appSupport = URL.applicationSupportDirectory.appendingPathComponent(bundleID)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let path = appSupport.appendingPathComponent("mcp.sock").path

        // 清理上次崩溃留下的僵尸 socket
        try? FileManager.default.removeItem(atPath: path)

        // 创建 socket
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.error("socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        // bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= 104 else {
            log.error("Socket path too long: \(path)")
            Darwin.close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                _ = pathBytes.withUnsafeBytes { src in
                    memcpy(dest, src.baseAddress!, pathBytes.count)
                }
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                Darwin.bind(fd, sap, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            log.error("bind() failed: \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            return
        }

        // listen
        guard Darwin.listen(fd, 8) == 0 else {
            log.error("listen() failed: \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            try? FileManager.default.removeItem(atPath: path)
            return
        }

        // accept loop 用 DispatchSource。
        // 注意 (Swift 6 严格并发):
        // start() 是 @MainActor,直接在这里写 setEventHandler { ... } 闭包会
        // 继承 MainActor 隔离。DispatchSource 在后台 queue 调用闭包时,运行时
        // _swift_task_checkIsolatedSwift -> dispatch_assert_queue_fail (BRK 1) 崩溃。
        // 解决:把 source 创建 + handler 安装放到 nonisolated static helper 里,
        // 那里的闭包默认 nonisolated,跑在后台 queue 上不会触发 isolation 检查。
        let source = Self.makeAcceptSource(listenFD: fd)
        source.resume()

        self.listenFD = fd
        self.acceptSource = source
        self.router = MCPRequestRouter(container: container)
        self.socketPath = path
        log.info("MCP server listening on \(path)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        if let path = socketPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        socketPath = nil
        router = nil
    }

    /// nonisolated —— 创建并配置 DispatchSource。这里的闭包不会继承
    /// MainActor 隔离,可以安全在后台 queue 上跑。
    nonisolated private static func makeAcceptSource(listenFD: Int32) -> DispatchSourceRead {
        let queue = DispatchQueue(label: "com.lifedever.pastememo.mcp.accept")
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD >= 0 {
                Self.spawnClientReadLoop(fd: clientFD)
            }
        }
        source.setCancelHandler {
            Darwin.close(listenFD)
        }
        return source
    }

    /// 每个 client 一个独立 detached task,串行处理它的 NDJSON 行。
    /// nonisolated static —— 不引用任何 MainActor isolated 状态,
    /// 安全从后台 dispatch queue 调用。read/send 都跑在 detached task 上(后台线程),
    /// 不阻塞主线程;只有路由 JSON-RPC 时才 hop 到 MainActor。
    nonisolated private static func spawnClientReadLoop(fd: Int32) {
        Task.detached {
            await Self.readLoop(fd: fd)
        }
    }

    /// nonisolated —— 阻塞 recv/send 必须在后台线程跑,绝不能在 MainActor 上。
    /// 每个连接维护一份 MCPClientContext,生命周期跟 readLoop 绑死;
    /// initialize 阶段会把 clientInfo.name 写进去,后续 tools/call 给 SetClipboardTool 用。
    nonisolated private static func readLoop(fd: Int32) async {
        let context = MCPClientContext()
        var buffer = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while !Task.isCancelled {
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                Darwin.recv(fd, ptr.baseAddress, ptr.count, 0)
            }
            if n <= 0 {
                Darwin.close(fd)
                return
            }
            buffer.append(buf, count: n)
            // NDJSON: 每行一条 JSON-RPC 消息
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                guard !line.isEmpty else { continue }
                await processLine(line, fd: fd, context: context)
            }
        }
        Darwin.close(fd)
    }

    /// nonisolated —— 解析 JSON 在后台,只在 router.handle 那一步 hop 到 MainActor。
    nonisolated private static func processLine(_ line: Data, fd: Int32, context: MCPClientContext) async {
        let req: JSONRPCRequest
        do {
            req = try JSONDecoder().decode(JSONRPCRequest.self, from: line)
        } catch {
            log.error("Parse error: \(error.localizedDescription)")
            return
        }
        // hop 到 MainActor 拿 router 并执行 handle;Router 是 @MainActor。
        let response: JSONRPCResponse? = await { @MainActor in
            guard let router = MCPSocketServer.shared.router else { return nil }
            return await router.handle(req, context: context)
        }()
        guard let response else { return }
        do {
            var data = try JSONEncoder().encode(response)
            data.append(0x0A)
            data.withUnsafeBytes { buf in
                _ = Darwin.send(fd, buf.baseAddress, buf.count, 0)
            }
        } catch {
            log.error("Encode error: \(error.localizedDescription)")
        }
    }
}
