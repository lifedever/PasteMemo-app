import Testing
@testable import PasteMemo

/// issue #89 的两个原始例子（小红书分享文案、百度网盘链接 + 提取码）是这里的基准
/// 用例——它们整条都不是 URL，所以 `.link` 那条路径拿不到，必须由片段抽取兜住。
@Suite("TextEntityExtractor Tests")
struct TextEntityExtractorTests {

    // MARK: - Links

    @Test("分享文案里的短链被认出来，显示 host")
    func linkInsideShareBlurb() {
        let text = "开源！macOS智能剪切板工具 🎉 PasteMemo v1.0.0 正式... https://xhslink.cn/o/2rEaAbPLcgk \n把口令拷走，打开【小红书】查看详情~"
        let entities = TextEntityExtractor.entities(in: text)
        let links = entities.filter { $0.kind == .link }
        #expect(links.count == 1)
        #expect(links.first?.display == "xhslink.cn")
        #expect(links.first?.value == "https://xhslink.cn/o/2rEaAbPLcgk")
        // "把口令拷走" 不带码候选，不能凭「口令」二字造出一个码
        #expect(!entities.contains { $0.kind == .code })
    }

    @Test("网盘文案同时给出链接和提取码")
    func linkAndCodeInNetdiskBlurb() {
        let text = """
        通过网盘分享的文件：Untitled.txt
        链接: https://pan.example.com/s/1x2nCtyV32iXtoEj9Sx5aNA?pwd=nx32 提取码: nx32
        --来自某网盘超级会员v5的分享
        """
        let entities = TextEntityExtractor.entities(in: text)
        #expect(entities.filter { $0.kind == .link }.first?.display == "pan.example.com")
        #expect(entities.filter { $0.kind == .code }.first?.value == "nx32")
    }

    @Test("整条内容就是一个链接时不出片段动作")
    func wholeContentIsLink() {
        // 这种条目会被判成 `.link`，⌘↩ 本来就能打开，面板里再列一条是重复
        #expect(TextEntityExtractor.entities(in: "https://example.com/a/b").isEmpty)
        #expect(TextEntityExtractor.entities(in: "  https://example.com/a/b  ").isEmpty)
    }

    @Test("没有可操作片段的文本返回空")
    func plainTextHasNoEntities() {
        #expect(TextEntityExtractor.entities(in: "今天下午三点开会，把上周的数据整理一下").isEmpty)
        #expect(TextEntityExtractor.entities(in: "").isEmpty)
        // 版本号不是链接，也不是码
        #expect(TextEntityExtractor.entities(in: "升级到 PasteMemo v1.10.1 之后好了").isEmpty)
    }

    @Test("同一个 host 的多个链接只留第一个")
    func dedupesByHost() {
        let text = "详情 https://example.com/a 备用 https://example.com/b 谢谢"
        let links = TextEntityExtractor.entities(in: text).filter { $0.kind == .link }
        #expect(links.count == 1)
        #expect(links.first?.value == "https://example.com/a")
    }

    @Test("链接最多列两个")
    func capsLinkCount() {
        let text = "一 https://a.example.com 二 https://b.example.com 三 https://c.example.com"
        let links = TextEntityExtractor.entities(in: text).filter { $0.kind == .link }
        #expect(links.count == 2)
        #expect(links.map(\.display) == ["a.example.com", "b.example.com"])
    }

    @Test("邮箱不算「能打开」的链接")
    func emailIsNotALink() {
        // NSDataDetector 会把邮箱认成 mailto:，那在这个面板里没有「打开」的语义
        let entities = TextEntityExtractor.entities(in: "有问题发 support@example.com 给我")
        #expect(entities.filter { $0.kind == .link }.isEmpty)
    }

    @Test("超长文本只扫开头，不拖慢面板")
    func scanLimitKeepsHeadEntities() {
        let head = "链接 https://example.com/x 提取码: ab12\n"
        let text = head + String(repeating: "日志行 no entity here\n", count: 500)
        let entities = TextEntityExtractor.entities(in: text)
        #expect(entities.contains { $0.kind == .link && $0.display == "example.com" })
        #expect(entities.contains { $0.kind == .code && $0.value == "ab12" })
    }

    @Test("文件名不是链接——.md / .sh / .py 都是真实 TLD")
    func filenameIsNotALink() {
        for text in [
            "看一下 readme.md 里的说明",
            "跑 build.sh 就行",
            "报错在 main.py 第 12 行",
            "日志在 app.log 里",
        ] {
            #expect(
                TextEntityExtractor.entities(in: text).filter { $0.kind == .link }.isEmpty,
                "\(text) 不该出链接动作"
            )
        }
        // 写了 scheme 的照常放行，即使域名末段撞上扩展名
        let explicit = TextEntityExtractor.entities(in: "文档在 https://docs.example.md/a 这里")
        #expect(explicit.contains { $0.kind == .link && $0.display == "docs.example.md" })
    }

    @Test("带路径的裸域名仍算链接")
    func bareDomainWithPathIsALink() {
        let links = TextEntityExtractor.entities(in: "戳 example.com/share/abc 看看").filter { $0.kind == .link }
        #expect(links.first?.display == "example.com")
    }

    // MARK: - 条目级入口

    @MainActor
    @Test("纯文本条目给出内容里的片段")
    func entitiesForPlainTextItem() {
        let item = ClipItem(content: "看这个 https://xhslink.cn/o/abc 提取码: nx32", contentType: .text)
        let entities = TextEntityExtractor.entities(for: item)
        #expect(entities.first { $0.kind == .link }?.display == "xhslink.cn")
        #expect(entities.first { $0.kind == .code }?.value == "nx32")
    }

    @MainActor
    @Test("敏感条目一个片段都不给")
    func entitiesSkipSensitiveItem() {
        let item = ClipItem(content: "看这个 https://xhslink.cn/o/abc 提取码: nx32", contentType: .text)
        item.isSensitive = true
        #expect(TextEntityExtractor.entities(for: item).isEmpty)
        // 取消敏感后立刻恢复
        item.isSensitive = false
        #expect(!TextEntityExtractor.entities(for: item).isEmpty)
    }

    @MainActor
    @Test("link / code 类型条目不扫片段")
    func entitiesSkipNonPlainTextTypes() {
        // .link 条目由面板用 item.resolvedURL 列「打开链接」
        #expect(TextEntityExtractor.entities(for: ClipItem(content: "https://example.com/a", contentType: .link)).isEmpty)
        // 代码里的 URL 是代码的一部分
        let code = ClipItem(content: "let url = \"https://api.example.com/v1\"", contentType: .code)
        #expect(TextEntityExtractor.entities(for: code).isEmpty)
    }

    // MARK: - ⌘K 里 `P` 该开的链接

    @MainActor
    @Test("混合文本：开解析出来的那个链接，标签带 host")
    func openableLinkForMixedText() {
        let item = ClipItem(content: "看这个 https://xhslink.cn/o/abc 打开小红书", contentType: .text)
        let link = TextEntityExtractor.openableLink(for: item)
        #expect(link?.url == "https://xhslink.cn/o/abc")
        #expect(link?.display == "xhslink.cn")
    }

    @MainActor
    @Test("link 条目：开自己，标签用通用的「打开链接」")
    func openableLinkForLinkItem() {
        let item = ClipItem(content: "https://example.com/a", contentType: .link)
        let link = TextEntityExtractor.openableLink(for: item)
        #expect(link?.url == "https://example.com/a")
        #expect(link?.display == nil)
    }

    @MainActor
    @Test("没有链接的文本不给 P 键动作")
    func openableLinkAbsentForPlainText() {
        let item = ClipItem(content: "今天下午三点开会", contentType: .text)
        #expect(TextEntityExtractor.openableLink(for: item) == nil)
    }

    @MainActor
    @Test("敏感的混合文本不把 host 印到菜单上")
    func openableLinkSkipsSensitiveMixedText() {
        let item = ClipItem(content: "看这个 https://xhslink.cn/o/abc 打开小红书", contentType: .text)
        item.isSensitive = true
        #expect(TextEntityExtractor.openableLink(for: item) == nil)
        item.isSensitive = false
        #expect(TextEntityExtractor.openableLink(for: item)?.display == "xhslink.cn")
    }

    @MainActor
    @Test("内容被改写后缓存要失效")
    func openableLinkCacheInvalidatesOnEdit() {
        let item = ClipItem(content: "看这个 https://first.example.com/a", contentType: .text)
        #expect(TextEntityExtractor.openableLink(for: item)?.display == "first.example.com")
        // 自动化规则改写过内容之后，不能还回上一个链接
        item.content = "换成 https://second.example.com/b 了"
        #expect(TextEntityExtractor.openableLink(for: item)?.display == "second.example.com")
        item.content = "现在一个链接都没有了"
        #expect(TextEntityExtractor.openableLink(for: item) == nil)
    }
}
