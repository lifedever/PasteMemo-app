import Foundation
import AppKit

/// 诊断日志 —— 抓「App 运行一段时间后打不开设置/管理器」这类只在真机长期运行后才
/// 出现、本机/单测都复现不了的 bug。
///
/// 设计铁律 = 绝不静默失败(见全局 CLAUDE.md「埋点没输出」的反复踩坑):
///  1. 路径按 `Bundle.main.bundleIdentifier` 派生 → dev(`…pastememo.dev`)与正式版
///     (`…pastememo`)各写各的目录,**不写死、不互相覆盖**,两者可同时运行。
///  2. 每次写入都先建目录+建文件,`FileHandle` 拿不到就降级原子写 —— 杜绝
///     「文件不存在 → handle 返回 nil → 写入静默丢」这条老坑。
///  3. 启动自检:写标记 → 立刻读回校验 → 把健康状态(`isHealthy`)暴露给 UI;
///     坏了用户在菜单里看到 ⚠️,而不是事后才发现一片空白。
///  4. **只记窗口/场景/生命周期事件,绝不记剪贴板内容** → 可安全公开贴到 issue。
///  5. 文件 1MB 封顶,超了保留后半段 —— 挂几天也不会撑爆。
///
/// 查清 bug 后整体移除(此文件 + 各调用点)。
enum DiagnosticLog {

    /// `~/Library/Logs/<bundleID>/diagnostic.log`
    static let fileURL: URL = {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lifedever.pastememo"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(bundleID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostic.log")
    }()

    /// 启动自检是否通过(写入并读回成功)。供菜单显示健康状态。
    nonisolated(unsafe) private(set) static var isHealthy = false

    private static let queue = DispatchQueue(label: "com.lifedever.pastememo.diaglog")
    private static let maxBytes = 1_000_000

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    /// 线程安全、可从任意线程(含 deinit)调用。每次写入都检查大小,超过上限就只保留
    /// 最近的一半 —— 即便长时间挂着不重启,文件也封顶在 ~1MB,不会无限增长。
    nonisolated static func log(_ msg: String) {
        let data = Data("[\(stamp())] \(msg)\n".utf8)
        queue.sync {
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let fh = try? FileHandle(forWritingTo: fileURL) else {
                let existing = (try? Data(contentsOf: fileURL)) ?? Data()
                try? (existing + data).write(to: fileURL)
                return
            }
            let size = (try? fh.seekToEnd()) ?? 0
            if size > UInt64(maxBytes) {
                try? fh.close()
                let old = (try? Data(contentsOf: fileURL)) ?? Data()
                let kept = old.suffix(maxBytes / 2) + data
                try? kept.write(to: fileURL)
            } else {
                try? fh.write(contentsOf: data)
                try? fh.close()
            }
        }
    }

    /// 启动时调用一次:截断 → 写带 token 的 session 头 → 读回校验。
    @discardableResult
    static func runSelfCheck() -> Bool {
        let token = "HEALTHCHECK-\(UInt64(Date().timeIntervalSince1970 * 1000))"
        log("──────── session start · \(token) · bundle=\(Bundle.main.bundleIdentifier ?? "?") ────────")
        let back = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        isHealthy = back.contains(token)
        return isHealthy
    }

    /// 导出日志:弹存储面板让用户自己选位置。
    /// **用非阻塞的 `begin(completionHandler:)`,不用 `runModal()`** —— 模态会堵住
    /// accessory app 的事件循环,一旦面板溜到别的窗口后面,整个 App(含状态栏菜单)
    /// 就卡死。`begin` 是异步的:用户不选、不理会它,App 照样能点,绝不卡。
    @MainActor
    static func exportLog() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lifedever.pastememo"

        let panel = NSSavePanel()
        panel.title = "导出诊断日志 / Export Diagnostics"
        panel.nameFieldStringValue = "PasteMemo-diagnostic-\(bundleID).log"
        panel.canCreateDirectories = true
        panel.directoryURL = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        panel.level = .modalPanel   // 浮在最前,不容易被别的窗口盖住

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in   // 非阻塞:不会卡住 app
            guard response == .OK, let dest = panel.url else {
                log("exportLog: user cancelled")
                return
            }
            try? fm.removeItem(at: dest)
            let ok = (try? fm.copyItem(at: fileURL, to: dest)) != nil
            log("exportLog: saved ok=\(ok) -> \(dest.lastPathComponent)")
            if ok {
                // 用户自选位置(可见),导出成功后自动在 Finder 里揭示
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
        }
    }

    /// 当前所有窗口的「指纹」:identifier + 可见性(locale 无关,不依赖本地化标题)。
    @MainActor
    static func windowSnapshot() -> String {
        NSApp.windows.map { w in
            let id = w.identifier?.rawValue ?? "nil"
            return "\(id)|vis:\(w.isVisible ? 1 : 0)"
        }.joined(separator: " ; ")
    }

    /// 开窗动作触发后延迟再拍一次窗口快照,看窗口到底有没有真出现。
    @MainActor
    static func logWindowsAfter(_ tag: String, delay: Double = 0.8) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            log("\(tag): +\(delay)s windows=[\(windowSnapshot())]")
        }
    }

}

/// 放进会随主窗口场景一起被 SwiftUI 创建/销毁的 @StateObject。
/// 如果哪天它 deinit 了,就证明「主窗口视图被 SwiftUI 拆掉了」——
/// 这正是验证「缓存的 openWindow/openSettings 是否会因视图销毁而失效」的关键信号。
final class WindowLifecycleProbe: ObservableObject {
    private let label: String
    init(_ label: String) {
        self.label = label
        DiagnosticLog.log("VIEW \(label): created (alive)")
    }
    deinit {
        DiagnosticLog.log("🔥 VIEW \(label): DEINIT — SwiftUI tore the view down")
    }
}
