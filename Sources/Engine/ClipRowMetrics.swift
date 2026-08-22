import AppKit
import Foundation

/// 列表行副行的「量级」计量：字数/行数、图片尺寸、链接域名。
///
/// 设计前提是**只在有量级差异时才发声**——两条 40 字的文案之间差几个字毫无
/// 辨识度，给每一行都挂个数字尾巴只会变成噪音；能区分「一句话」和「一整份
/// JSON」的才值得占用副行的位置。所以短文本一律返回 nil。
///
/// 计算全部走 `nonisolated` 纯函数 + 内存缓存，**不入库**：ClipItemStore 监听
/// `NSManagedObjectContextDidSave` 刷新整个列表，若把计量写回 SwiftData，滚动
/// 时的懒补就会变成 0.5s 一次的全列表 refresh 风暴。
enum ClipRowMetrics {
    // MARK: - 阈值

    /// 文本/代码低于这个字符数不报字数。
    ///
    /// 门槛的依据是**标题栏截断的位置**，不是内容的绝对量级：计量真正的用处是
    /// 告诉你「标题之外还剩多少」。快捷面板的标题大约显示 20 个中文字符，所以
    /// 30 字以上必然已经截断，字数才开始有信息量；再短的词和短语标题本就完整
    /// 显示，报数字纯属噪音（用户库里 58% 的单行文本都在 15 字以内）。
    static let minChars = 30
    /// 行数达到这个值才报行数。
    ///
    /// 取 2 是因为标题只取第一行——只要存在第二行，标题就必然没显示全。
    static let minLines = 2
    /// 超过这个体积的文本改报字节数：「3,441,204 字」没人读得出量级，「12.4 MB」可以。
    /// 同时也是精确 grapheme 计数的上限（`String.count` 是 O(n)）。
    static let bulkTextBytes = 1 << 20  // 1 MB
    /// 链接解析只看开头这么多字符——超长 URL 不值得整串解析。
    static let linkParseCap = 2048

    // MARK: - 缓存键

    /// 计量的缓存键兼重算触发键。
    ///
    /// **刻意不含内容长度**：SwiftData 取出的 String 往往还是 NSString 桥接态，
    /// `count` / `utf8.count` 在那种状态下是 O(n)，放进每帧求值的 `body` 会让滚动
    /// 随条目大小线性劣化。改用 `displayTitle` 当内容版本信号——它由 `buildTitle`
    /// 生成（文本截到 200 字），内容一被编辑就会重算，长度又有界。
    ///
    /// 带 `language` 是因为缓存的是成品文案，切换界面语言后必须重出。
    struct Key: Hashable, Sendable {
        let itemID: String
        let titleSnapshot: String
        let language: String
    }

    // MARK: - 测量结果

    struct TextMetrics: Equatable, Sendable {
        /// 字符数（grapheme）。超大文本不精确计数，此时为 nil。
        let chars: Int?
        /// 行数。超大文本同样为 nil。
        let lines: Int?
        let bytes: Int
    }

    struct ImageMetrics: Equatable, Sendable {
        let width: Int
        let height: Int
        /// 原图字节数；读不到（文件已删/无 stat 权限）时为 nil。
        let bytes: Int?
    }

    // MARK: - 测量（纯函数，可在后台线程跑）

    /// 文本/代码的字数与行数。
    ///
    /// `utf8.count` 是 O(1)，先用它挡掉绝大多数短文案（每个字符至少 1 字节，所以
    /// `utf8.count < minChars` 必然不够格），避免为一屏短文案跑 N 次 O(n) 计数。
    nonisolated static func measureText(_ content: String) -> TextMetrics {
        let bytes = content.utf8.count
        guard bytes > bulkTextBytes else {
            var lines = 1
            for byte in content.utf8 where byte == 0x0A { lines += 1 }
            return TextMetrics(chars: content.count, lines: lines, bytes: bytes)
        }
        return TextMetrics(chars: nil, lines: nil, bytes: bytes)
    }

    /// 图片的像素尺寸与原图体积。**必须在后台线程调用**：存在性检查是 stat、
    /// 尺寸要读文件头，两样都是 IO。
    ///
    /// 取值优先级与 `ClipItem.sourceImageFileURL` 一致（缓存的原图 → 用户的源文件），
    /// 但参数是主线程预先解出来的纯值——`ClipItem` 是 `@Model`，不能跨线程传。
    /// `legacyBytes` 只在「raw 截图且没有原图缓存文件」时才该有值：新条目的
    /// `imageData` 只是缩略图，拿它测会报出假尺寸。
    nonisolated static func measureImage(
        content: String,
        originalImagePath: String?,
        legacyBytes: Data?
    ) -> ImageMetrics? {
        let fm = FileManager.default
        if let path = originalImagePath, fm.fileExists(atPath: path) {
            return measure(fileAt: path)
        }
        if content != "[Image]" {
            // 多文件图片条目的 content 可能有几千行，只取第一行即可，不做整串切分。
            let firstPath = String(content.prefix(while: { $0 != "\n" }))
            if !firstPath.isEmpty, fm.fileExists(atPath: firstPath) {
                return measure(fileAt: firstPath)
            }
        }
        guard let legacyBytes, let size = imageDimensions(inData: legacyBytes) else { return nil }
        return ImageMetrics(width: Int(size.width), height: Int(size.height), bytes: legacyBytes.count)
    }

    private nonisolated static func measure(fileAt path: String) -> ImageMetrics? {
        let url = URL(fileURLWithPath: path)
        guard isCheapToRead(url) else { return nil }
        guard let size = imageDimensions(atFile: url) else { return nil }
        // 符号链接的 stat 只返回链接节点的大小（Telegram 的 *.jpg 软链就是这样），
        // 与属性面板一致地先解析再取体积。
        let resolved = url.resolvingSymlinksInPath()
        let bytes = (try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        return ImageMetrics(width: Int(size.width), height: Int(size.height), bytes: bytes)
    }

    /// 链接的显示域名（去掉 `www.`）。同步调用安全：解析长度有界。
    nonisolated static func linkHost(_ content: String) -> String? {
        // data URI 的 content 可能有好几 MB，而且压根没有 host 可言。
        guard !DataImageURI.isDataImageURI(content) else { return nil }
        let head = String(content.prefix(linkParseCap)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL.fromLinkString(head)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - 文案

    /// 文本计量的副行文案，不够格时返回 nil。
    @MainActor
    static func label(for metrics: TextMetrics) -> String? {
        // 超大文本：字数换成体积。
        guard let chars = metrics.chars, let lines = metrics.lines else {
            return formatBytes(metrics.bytes)
        }
        // 两个数字各自独立判断：每个只在它自己有信息量时出现。一条 5 字 2 行的
        // 内容值得报「2 行」（标题只显示了第一行），但报「5 字」没有意义。
        var parts: [String] = []
        if chars >= minChars {
            parts.append(L10n.tr("meta.chars", abbreviate(chars)))
        }
        if lines >= minLines {
            parts.append(L10n.tr("meta.lines", abbreviate(lines)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 图片计量的副行文案。`includeDimensions` 为 false 时只报体积——raw 截图的
    /// 标题已经是 `Image (W×H)`，副行再报一次尺寸是重复。
    @MainActor
    static func label(for metrics: ImageMetrics, includeDimensions: Bool = true) -> String? {
        var parts: [String] = []
        if includeDimensions {
            parts.append("\(metrics.width)×\(metrics.height)")
        }
        if let bytes = metrics.bytes, bytes > 0 {
            parts.append(formatBytes(bytes))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 数量缩写：348 / 1.2k / 3.4M。整数倍去掉小数位（12k 而不是 12.0k）。
    nonisolated static func abbreviate(_ value: Int) -> String {
        switch value {
        case ..<1_000:
            return "\(value)"
        // 上界不是 1_000_000 而是它的四舍五入下沿：999_999 走 k 路径会进位成
        // 「1000k」,不如直接报「1M」。
        case ..<999_950:
            return scaled(value, divisor: 1_000, suffix: "k")
        default:
            return scaled(value, divisor: 1_000_000, suffix: "M")
        }
    }

    private nonisolated static func scaled(_ value: Int, divisor: Int, suffix: String) -> String {
        let tenths = (value * 10 + divisor / 2) / divisor
        let whole = tenths / 10
        let fraction = tenths % 10
        return fraction == 0 ? "\(whole)\(suffix)" : "\(whole).\(fraction)\(suffix)"
    }

    /// 复用同一个 formatter：`ByteCountFormatter()` 每次初始化都要查 locale，
    /// 滚动采样里它已经能占到主线程的可见份额了。只在 `@MainActor` 上使用，
    /// 所以共享实例没有并发问题。
    @MainActor private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    @MainActor private static func formatBytes(_ bytes: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(bytes))
    }

    /// 这个文件读起来会不会「不可预期地慢」。
    ///
    /// 列表缩略图画的是数据库里的 `imageData`，**从不碰用户的原文件**——所以这里
    /// 读文件头是纯新增的 IO，没有既有读取替我们预热过。两种文件读下去会失控：
    /// - **iCloud 上没下载的（dataless file）**：读操作会触发实体化下载，可能几秒起步，
    ///   还费流量。为了列表上一行灰字去下载用户的文件是完全不成比例的。
    /// - **网络卷（SMB/NAS）**：延迟不可预期，串行队列上一个慢文件会堵住后面所有测量。
    ///
    /// 两个检查本身都是 stat 级别的元数据查询，不会触发下载。外接 USB 硬盘
    /// `volumeIsLocal` 为 true，照常测量。
    private nonisolated static func isCheapToRead(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey])
        else { return true }  // 问不出来就按能读处理，行为不比改动前差
        if values.isUbiquitousItem == true { return false }
        if values.volumeIsLocal == false { return false }
        return true
    }

    // MARK: - 无解码的图片头读取

    private nonisolated static func imageDimensions(atFile url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return dimensions(from: source)
    }

    private nonisolated static func imageDimensions(inData data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return dimensions(from: source)
    }

    private nonisolated static func dimensions(from source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = props[kCGImagePropertyPixelHeight] as? CGFloat,
              // 损坏/元数据异常的图片能读出 0——「0×0」比不显示更糟。
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// 行计量的执行闸门：所有测量都排在这个 actor 上串行跑。
///
/// 不用 `Task.detached` 是因为测量里全是**阻塞式 syscall**（stat、读图片文件头）
/// 和 O(n) 遍历。detached 任务跑在 Swift 并发的协作线程池上，池宽只有 CPU 核心数
/// ——快速滚过几百个图片行就会派出几百个并发 IO 任务，把池子占满，连累 App 里
/// 其他所有 async 工作（OCR、搜索）。串行化后最多占用一个池线程。
///
/// 附带好处：actor 调用是结构化的，行滚出屏幕时 `.task` 的取消能传进来，
/// 排队中的测量直接作废——`Task.detached` 不继承取消，做不到这点。
actor ClipMetricsWorker {
    static let shared = ClipMetricsWorker()

    private init() {}

    func measureText(_ content: String) -> ClipRowMetrics.TextMetrics? {
        guard !Task.isCancelled else { return nil }
        // 连长度查询都留在这儿：`utf8.count` 在 NSString 桥接态下是 O(n)，
        // 主线程上不该碰。够不够格显示由 `ClipRowMetrics.label(for:)` 判定。
        return ClipRowMetrics.measureText(content)
    }

    func measureImage(
        content: String,
        originalImagePath: String?,
        legacyBytes: Data?
    ) -> ClipRowMetrics.ImageMetrics? {
        guard !Task.isCancelled else { return nil }
        return ClipRowMetrics.measureImage(
            content: content,
            originalImagePath: originalImagePath,
            legacyBytes: legacyBytes
        )
    }
}

/// 行计量的**成品文案**缓存。
///
/// 存最终字符串而不是中间结果，是为了让 `body` 退化成一次字典查找：格式化要走
/// `L10n.tr`（bundle 查表）+ `String(format:)`，放在每帧每行求值的 body 里，一屏
/// 几十行就是几十次多余的查表。
///
/// 键见 `ClipRowMetrics.Key`：条目 ID + 标题快照 + 语言。缓存 `nil` 同样有意义——
/// 「测过，这条不够格显示」，否则每次重绘都要为短文案重跑一遍判定，图片行更是
/// 每次都重来一轮 IO。
@MainActor
final class ClipMetricsCache {
    static let shared = ClipMetricsCache()

    /// 外层 Optional = 有没有测过；内层 = 测出来该不该显示。
    private var labels: [ClipRowMetrics.Key: String?] = [:]

    /// 上限：快捷面板可以一直往下滚，字典无限增长就是内存泄漏。超限直接清空——
    /// 没有 LRU 信息，清一半也只是随机淘汰，不如让可见行重测一次。
    private let capacity = 4_000

    private init() {}

    func cachedLabel(forKey key: ClipRowMetrics.Key) -> String?? { labels[key] }

    func setLabel(_ label: String?, forKey key: ClipRowMetrics.Key) {
        if labels.count >= capacity { labels.removeAll(keepingCapacity: true) }
        labels[key] = label
    }

    func clear() { labels.removeAll() }
}
