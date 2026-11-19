import SwiftUI
import AppKit

/// 贴边条卡片的尺寸规则。所有类型共用三档宽度：短的窄、长的宽，一排里只有三种宽度。
/// 各类型各算各的宽度时一排能出现十种宽度，看着乱。
enum ShelfCardMetrics {
    static let narrowWidth: CGFloat = 132
    static let mediumWidth: CGFloat = 180
    static let wideWidth: CGFloat = 240

    static let height: CGFloat = 152
    static let metaHeight: CGFloat = 28
    static let bodyHeight: CGFloat = height - metaHeight
    static let spacing: CGFloat = 10
    static let cornerRadius: CGFloat = 10

    @MainActor
    static func width(for item: ClipItem) -> CGFloat {
        if item.isSensitive || isMultiFile(item) { return mediumWidth }
        switch item.contentType {
        case .image:
            return imageWidth(aspect: ImageAspectCache.aspect(for: item))
        case .color: return narrowWidth
        case .code: return wideWidth
        case .link, .file, .document, .archive, .application, .video, .audio: return mediumWidth
        default: return textWidth(for: ShelfCardText.preview(of: item))
        }
    }

    /// 图片卡：竖图窄、方图中、横图宽，卡片里裁切铺满
    static func imageWidth(aspect: CGFloat) -> CGFloat {
        if aspect < 0.8 { return narrowWidth }
        if aspect <= 1.3 { return mediumWidth }
        return wideWidth
    }

    /// 文字卡：一行短字用窄卡大字，多行或很长用宽卡，其余中等
    static func textWidth(for text: String) -> CGFloat {
        if ShelfCardText.isShort(text) { return narrowWidth }
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        if lineCount > 2 || text.count > 60 { return wideWidth }
        return mediumWidth
    }

    static func isMultiFile(_ item: ClipItem) -> Bool {
        item.contentType.isFileBased && item.content.contains("\n")
    }
}

enum ShelfCardText {
    /// 卡片最多显示这么多字，再多也会被裁掉，不必交给排版
    static let previewLimit = 400

    static func preview(of item: ClipItem) -> String {
        String(item.content.prefix(previewLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 一行、16 个字以内算短文字：用大字号，一眼能读完
    static func isShort(_ text: String) -> Bool {
        text.count <= 16 && !text.contains("\n")
    }
}

/// 贴边条里的一张卡片。只负责画；选中、粘贴等行为由 QuickPanelView 处理。
struct ShelfCardView: View {
    let item: ClipItem
    /// 键盘焦点所在的卡片：粗描边
    let isFocused: Bool
    /// 被勾选进多选：细描边
    let isPicked: Bool
    /// 勾选顺序，从 1 开始；粘贴按这个顺序
    let pickOrder: Int?
    /// 按住 ⌘ 时显示的 ⌘1–9 编号
    let shortcutNumber: Int?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var highlightedCode: AttributedString?
    @State private var characterCount: Int?

    private var width: CGFloat { ShelfCardMetrics.width(for: item) }
    private var radius: CGFloat { ShelfCardMetrics.cornerRadius }

    var body: some View {
        VStack(spacing: 0) {
            face
                .frame(width: width, height: ShelfCardMetrics.bodyHeight, alignment: .topLeading)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius))
            metaLine
                .frame(width: width, height: ShelfCardMetrics.metaHeight)
        }
        .background(cardFill, in: RoundedRectangle(cornerRadius: radius))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(borderColor, lineWidth: isFocused ? 2 : (isPicked ? 1.5 : 0.5))
        )
        .overlay(alignment: .topTrailing) {
            if let pickOrder { pickBadge(pickOrder) }
        }
        .shadow(color: .black.opacity(isFocused ? 0.2 : 0), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: radius))
        .onHover { isHovered = $0 }
    }

    // MARK: - 卡片面

    @ViewBuilder
    private var face: some View {
        if item.isSensitive, !OptionKeyMonitor.shared.isOptionPressed {
            sensitiveFace
        } else if ShelfCardMetrics.isMultiFile(item) {
            fileFace
        } else {
            switch item.contentType {
            case .image: imageFace
            case .link: linkFace
            case .code: codeFace
            case .color:
                if let parsed = ColorConverter.parse(item.content) { colorFace(parsed) } else { textFace }
            case .file, .document, .archive, .application, .video, .audio: fileFace
            case .mixed:
                if item.imageData != nil { imageFace } else { textFace }
            default: textFace
            }
        }
    }

    private var textFace: some View {
        let text = ShelfCardText.preview(of: item)
        let isShort = ShelfCardText.isShort(text)
        return Text(text)
            .font(isShort ? .system(size: 16, weight: .medium) : .system(size: 12.5))
            .lineSpacing(isShort ? 1 : 2.5)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .mask(bottomFade)
    }

    private var linkFace: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                favicon
                Text(linkHost)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let title = item.linkTitle, !title.isEmpty {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            Text(item.content)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.top, 11)
    }

    /// 图片卡是「相框」：图片缩进、圆角、细描边、一点投影，底下垫浅灰底。
    /// 铺满整张卡片时，白底的文字截图和文字卡长得一样，分不清是图还是字。
    private var imageFace: some View {
        AsyncPreviewImageView(
            data: item.imageData,
            cacheKey: item.itemID,
            maxPixelSize: 320,
            cornerRadius: 0,
            thumbnailSize: 320,
            fallbackFileURL: item.imageData == nil ? item.sourceImageFileURL : nil,
            contentMode: .fill
        )
        .frame(width: width - Self.imageInset * 2, height: ShelfCardMetrics.bodyHeight - Self.imageInset)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        .padding([.horizontal, .top], Self.imageInset)
        .frame(width: width, height: ShelfCardMetrics.bodyHeight, alignment: .top)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.045))
        // 图片自己的双击手势会吞掉第二次点击，整张卡片的「双击粘贴」就不触发了
        .allowsHitTesting(false)
    }

    private static let imageInset: CGFloat = 6

    private var codeFace: some View {
        Text(highlightedCode ?? AttributedString(codeSnippet))
            .font(.system(size: 10.5, design: .monospaced))
            .lineSpacing(2)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
            .background(
                colorScheme == .dark ? Color.black.opacity(0.28) : Color.primary.opacity(0.05),
                in: UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7)
            )
            .padding([.horizontal, .top], 8)
            .mask(bottomFade)
            .task(id: "\(item.itemID)-\(colorScheme == .dark)") { await highlightCode() }
    }

    /// 颜色只放在小圆色块里，卡片保持中性底色——整块铺满颜色在一排卡片里太跳
    private func colorFace(_ parsed: ParsedColor) -> some View {
        let color = Color(nsColor: parsed.nsColor)
        let luminance: CGFloat = 0.299 * parsed.r + 0.587 * parsed.g + 0.114 * parsed.b
        let isPale = luminance / 255 > 0.85
        return VStack(spacing: 11) {
            Circle()
                .fill(color)
                .frame(width: 52, height: 52)
                .overlay(Circle().strokeBorder(Color.primary.opacity(isPale ? 0.18 : 0.08), lineWidth: isPale ? 1 : 0.5))
                .shadow(color: isPale ? .black.opacity(0.12) : color.opacity(0.35), radius: 7, y: 4)
            VStack(spacing: 5) {
                Text(item.content.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(parsed.formatted(parsed.alternateFormat))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 4)
    }

    private var fileFace: some View {
        let paths = filePaths
        return VStack(spacing: 10) {
            if paths.count > 1 {
                ZStack {
                    ForEach(Array(paths.prefix(3).enumerated()), id: \.offset) { index, path in
                        fileIcon(path, size: 40)
                            .rotationEffect(.degrees(Double(index - 1) * 10))
                            .offset(x: CGFloat(index - 1) * 14)
                    }
                }
                .frame(height: 48)
            } else {
                fileIcon(paths.first ?? "", size: 46)
            }
            Text(item.displayTitle ?? URL(fileURLWithPath: paths.first ?? "").lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sensitiveFace: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
            Text(SensitiveTextMask.partial(item.content))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底栏

    /// 左边来源 App + 时间（中、宽卡再跟一条信息），右边类型胶囊。
    /// 按住 ⌘ 时来源 App 的位置换成 ⌘1–9；窄卡放不下来源 App 就省掉，时间和类型保留。
    private var metaLine: some View {
        HStack(spacing: 5) {
            if let shortcutNumber {
                Text("⌘\(shortcutNumber)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4))
            } else if width >= ShelfCardMetrics.mediumWidth,
                      let icon = appIcon(forBundleID: item.sourceAppBundleID, name: item.sourceApp) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
            }
            metaText
                .lineLimit(1)
                .truncationMode(.tail)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
            }
            Spacer(minLength: 4)
            kindCapsule
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .task(id: item.itemID) { await countCharacters() }
    }

    private var metaText: Text {
        let time = Text(formatTimeAgo(item.lastUsedAt))
        guard width >= ShelfCardMetrics.mediumWidth, let info else { return time }
        return time + Text(" · ") + Text(info).font(.system(size: 10.5, design: .monospaced))
    }

    /// 类型胶囊：淡色底 + 彩色字。白底文字卡和白底文字截图光看内容分不清，每张卡都写明格式
    private var kindCapsule: some View {
        let kind = ShelfCardKind.of(item)
        let isDark = colorScheme == .dark
        return HStack(spacing: 3) {
            Image(systemName: kind.symbol)
                .font(.system(size: 8.5, weight: .bold))
            Text(kind.name)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(kind.tone.ink(isDark: isDark))
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .frame(height: 18)
        .background(kind.tone.base.opacity(isDark ? 0.2 : 0.13), in: Capsule())
        .fixedSize()
    }

    /// 底栏那条信息：文字写字数、图片写尺寸、链接写域名、代码写语言、文件写个数或扩展名。
    /// 敏感条目不给，字数也会泄露信息。
    private var info: String? {
        if item.isSensitive { return nil }
        if ShelfCardMetrics.isMultiFile(item) { return L10n.tr("shelf.card.files", filePaths.count) }
        switch item.contentType {
        case .image:
            guard let size = ImageAspectCache.pixelSize(for: item) else { return nil }
            return "\(Int(size.width))×\(Int(size.height))"
        case .link:
            return linkHost
        case .code:
            return item.resolvedCodeLanguage?.displayName
        case .file, .document, .archive, .application, .video, .audio:
            let ext = URL(fileURLWithPath: filePaths.first ?? "").pathExtension.uppercased()
            return ext.isEmpty ? nil : ext
        case .color:
            return nil
        case .mixed where item.imageData != nil:
            return nil
        default:
            return characterCount.map { L10n.tr("shelf.card.chars", $0) }
        }
    }

    /// 字数在后台数：粘贴过特别长的文字时，渲染时现数会卡
    private func countCharacters() async {
        guard characterCount == nil, !item.isSensitive else { return }
        let content = item.content
        let count = await Task.detached(priority: .utility) { content.count }.value
        guard !Task.isCancelled else { return }
        characterCount = count
    }

    private func pickBadge(_ order: Int) -> some View {
        Text("\(order)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(minWidth: 20, minHeight: 20)
            .background(Color.accentColor, in: Circle())
            .shadow(color: Color.accentColor.opacity(0.45), radius: 3, y: 1)
            .padding(6)
    }

    // MARK: - 小部件

    private var cardFill: Color {
        if colorScheme == .dark { return Color.white.opacity(isHovered ? 0.09 : 0.06) }
        return Color.white.opacity(isHovered ? 1 : 0.88)
    }

    private var borderColor: Color {
        if isFocused { return .accentColor }
        if isPicked { return Color.accentColor.opacity(0.6) }
        return Color.primary.opacity(0.08)
    }

    private var bottomFade: LinearGradient {
        LinearGradient(stops: [.init(color: .black, location: 0.72), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder
    private var favicon: some View {
        if let data = item.faviconData, let image = ImageCache.shared.favicon(for: data, key: item.content) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }

    private var linkHost: String {
        guard let host = item.resolvedURL?.host() else { return item.content }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var filePaths: [String] {
        item.content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func fileIcon(_ path: String, size: CGFloat) -> some View {
        Image(nsImage: ImageCache.shared.fileIcon(forPath: path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }

    /// 卡片里只看得到前十几行，高亮也只高亮这一段
    private var codeSnippet: String {
        let lines = item.content.prefix(800).split(separator: "\n", omittingEmptySubsequences: false).prefix(14)
        return lines.joined(separator: "\n")
    }

    private func highlightCode() async {
        let snippet = codeSnippet
        let language = item.resolvedCodeLanguage ?? CodeDetector.detectLanguage(snippet) ?? .unknown
        let tokens = await SyntaxHighlightWorker.shared.highlight(code: snippet, language: language.hljsName)
        guard !Task.isCancelled else { return }
        let theme = colorScheme == .dark ? SyntaxTheme.dark : SyntaxTheme.light
        var result = AttributedString()
        for token in tokens {
            var piece = AttributedString(token.text)
            piece.foregroundColor = Color(nsColor: token.scope.map { theme.color(forScope: $0) } ?? theme.plain)
            result += piece
        }
        highlightedCode = result
    }
}

// MARK: - 类型标识

/// 卡片底栏类型胶囊的名字、图标和颜色。颜色按类型分、不按来源 App 分：
/// 琥珀是文本、玫红是图片、蓝是链接、紫是代码……看几次就记住了。
struct ShelfCardKind {
    let name: String
    let symbol: String
    let tone: Tone

    enum Tone {
        case amber, pink, blue, violet, teal, slate, orange, red, emerald, gray
    }

    @MainActor
    static func of(_ item: ClipItem) -> ShelfCardKind {
        if item.isSensitive {
            return ShelfCardKind(name: L10n.tr("filter.sensitive"), symbol: "lock.fill", tone: .orange)
        }
        if ShelfCardMetrics.isMultiFile(item) {
            return ShelfCardKind(name: ClipContentType.file.label, symbol: "doc.on.doc", tone: .slate)
        }
        // 带图片的混合条目在卡片上显示成图片，就标图片
        let type: ClipContentType = item.contentType == .mixed && item.imageData != nil ? .image : item.contentType
        return ShelfCardKind(name: type.label, symbol: type.icon, tone: tone(for: type))
    }

    static func tone(for type: ClipContentType) -> Tone {
        switch type {
        case .text, .email, .phone: return .amber
        case .image: return .pink
        case .link: return .blue
        case .code: return .violet
        case .color: return .teal
        case .file, .document, .archive, .application: return .slate
        case .video: return .red
        case .audio: return .emerald
        case .mixed: return .gray
        }
    }
}

extension ShelfCardKind.Tone {
    /// 胶囊底色用的类型色（再按外观降不透明度）
    var base: Color {
        switch self {
        case .amber: Color(hex: 0xF59E0B)
        case .pink: Color(hex: 0xEC4899)
        case .blue: Color(hex: 0x3B82F6)
        case .violet: Color(hex: 0x8B5CF6)
        case .teal: Color(hex: 0x14B8A6)
        case .slate: Color(hex: 0x64748B)
        case .orange: Color(hex: 0xF97316)
        case .red: Color(hex: 0xEF4444)
        case .emerald: Color(hex: 0x10B981)
        case .gray: Color(hex: 0x6B7280)
        }
    }

    /// 胶囊上的字和图标：浅色外观用深一档，深色外观用浅一档，淡色底上才看得清
    func ink(isDark: Bool) -> Color {
        switch self {
        case .amber: Color(hex: isDark ? 0xFCD34D : 0xB45309)
        case .pink: Color(hex: isDark ? 0xF9A8D4 : 0xBE185D)
        case .blue: Color(hex: isDark ? 0x93C5FD : 0x1D4ED8)
        case .violet: Color(hex: isDark ? 0xC4B5FD : 0x6D28D9)
        case .teal: Color(hex: isDark ? 0x5EEAD4 : 0x0F766E)
        case .slate: Color(hex: isDark ? 0xCBD5E1 : 0x475569)
        case .orange: Color(hex: isDark ? 0xFDBA74 : 0xC2410C)
        case .red: Color(hex: isDark ? 0xFCA5A5 : 0xB91C1C)
        case .emerald: Color(hex: isDark ? 0x6EE7B7 : 0x047857)
        case .gray: Color(hex: isDark ? 0xD1D5DB : 0x4B5563)
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
