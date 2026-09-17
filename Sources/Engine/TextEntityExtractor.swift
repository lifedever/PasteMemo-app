import Foundation

/// 从混合文本里认出可直接操作的片段：链接、网盘提取码 / 验证码。
///
/// `ClipboardManager.detectContentType` 里的 `isURL` 是整串锚定的（`^https?://\S+$`），
/// 所以「分享文案 + 链接」这类内容一律落到 `.text`，`.link` 条目那套「打开链接 /
/// 预览标题」全都不触发——用户只能手动选中再走右键服务（issue #89：小红书分享文案、
/// 百度网盘链接 + 提取码）。这里补的是同一件事的片段版：认出来的片段交给 ⌘K 面板
/// 做成独立动作，条目本身的类型和内容都不动。
///
/// 只认边界唯一、动作唯一的片段。名词分词不在范围内：分出来的名词既没有确定边界
/// （"macOS智能剪切板工具" 该切几刀没有判据），也没有可绑的动作。
///
/// 纯文本逻辑、无系统依赖，可单测。
enum TextEntityExtractor {

    struct Entity: Hashable {
        enum Kind: Hashable {
            case link
            case code
        }
        let kind: Kind
        /// 要执行的值：链接是补好 scheme 的完整 URL，码是码本身。
        let value: String
        /// 面板行上显示的短标签——链接取 host，码就是码本身。
        let display: String
    }

    /// 面板里最多列几个链接。一条分享文案里塞两个以上不同域名的情况极少，列太多会把
    /// ⌘K 的高频动作（粘贴 / 复制）挤出视野。
    private static let MAX_LINKS = 2

    /// 只扫开头这些字符。剪贴板里可能是几 MB 的日志或 JSON，而可操作片段几乎总在
    /// 开头几行；`VerificationCodeExtractor` 内部另有 1000 字的截断。
    private static let SCAN_LIMIT = 2000

    static func entities(in text: String) -> [Entity] {
        let scanned = text.count > SCAN_LIMIT ? String(text.prefix(SCAN_LIMIT)) : text
        guard !scanned.isEmpty else { return [] }

        var result = links(in: scanned)
        if let code = VerificationCodeExtractor.extract(from: scanned) {
            result.append(Entity(kind: .code, value: code, display: code))
        }
        return result
    }

    // MARK: - 条目级入口

    /// 该给这个条目列哪些片段动作。哪些条目该扫的判断放在这里，不留在 View 里——
    /// 它决定了什么会被印到菜单行上，值得有测试盯着。
    ///
    /// - 只扫 `.text`：`.link` 整条就是链接，面板用 `item.resolvedURL` 列「打开链接」；
    ///   `.code` 里的 URL 是代码的一部分，复制一段代码不是为了打开里面的链接。
    /// - 敏感条目跳过：它在列表里是打码显示的（按住 Option 才露原文），菜单行把
    ///   host 和提取码原样印出来等于绕过那层遮蔽。
    @MainActor
    static func entities(for item: ClipItem) -> [Entity] {
        guard item.contentType == .text, !item.isSensitive, !item.content.isEmpty else { return [] }
        return entities(in: item.content)
    }

    /// ⌘K 里「打开链接」那行该开的东西，没有就返回 nil。`display` 为 nil 表示条目
    /// 整条就是链接（标签用通用的「打开链接」），否则是混合文本里解析出来的 host。
    ///
    /// ⌘↩ 不碰链接——它对所有条目一律是纯文本粘贴 / 粘贴路径。开链接只有 ⌘K 里的
    /// `P` 和 ⌘O 两个入口，两种条目在这件事上没有区别。
    ///
    /// 面板每次 body 求值都会问一遍，所以带缓存：抽取本身（关键词扫描 +
    /// NSDataDetector）不该跟着跑，面板同时只盯一个条目，命中率接近 100%。
    @MainActor
    static func openableLink(for item: ClipItem) -> (url: String, display: String?)? {
        let key = CacheKey(itemID: item.itemID, contentHash: item.content.hashValue, sensitive: item.isSensitive)
        if let cached, cached.key == key { return cached.link }

        let link = resolveOpenableLink(for: item)
        cached = (key: key, link: link)
        return link
    }

    @MainActor
    private static func resolveOpenableLink(for item: ClipItem) -> (url: String, display: String?)? {
        // 条目整条就是链接：用它自己的 resolvedURL（裸域名已经补好 scheme）
        if item.contentType == .link, let url = item.resolvedURL {
            return (url.absoluteString, nil)
        }
        guard let link = entities(for: item).first(where: { $0.kind == .link }) else { return nil }
        return (link.value, link.display)
    }

    private struct CacheKey: Equatable {
        let itemID: String
        let contentHash: Int
        let sensitive: Bool
    }

    @MainActor private static var cached: (key: CacheKey, link: (url: String, display: String?)?)?

    // MARK: - Links

    /// 复用一个 detector 实例：NSDataDetector 的构造要编译内部规则，每次 ⌘K 都新建
    /// 一个是白扔的开销。
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private static func links(in text: String) -> [Entity] {
        guard let detector = linkDetector else { return [] }
        let ns = text as NSString
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        var seenHosts = Set<String>()
        var result: [Entity] = []

        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url,
                  let host = url.host?.lowercased(), !host.isEmpty,
                  let scheme = url.scheme?.lowercased() else { continue }
            // 只要浏览器打得开的。detector 也会把邮箱认成 mailto:、把某些路径认成
            // file:，那些在这个面板里没有「打开」的语义。
            guard scheme == "http" || scheme == "https" else { continue }
            let raw = ns.substring(with: match.range)
            // 整条内容就是这个链接 → 这条目本身就是 `.link`，面板会用
            // `item.resolvedURL` 列「打开链接」，这里不必再给一条片段。
            guard raw != trimmed else { continue }
            // `readme.md`、`build.sh`、`main.py` 的后缀全是真实 TLD，detector 一律
            // 认成域名。带 scheme 的不查——写了 https:// 就是链接。
            guard raw.contains("://") || !URL.looksLikeFilename(raw) else { continue }
            // 同 host 只留第一个：同一条分享文案里的重复链接（短链 + 原链、正文 + 签名）
            // 列两行长得一样，选不出来。
            guard seenHosts.insert(host).inserted else { continue }

            result.append(Entity(kind: .link, value: url.absoluteString, display: host))
            if result.count >= MAX_LINKS { break }
        }
        return result
    }
}
