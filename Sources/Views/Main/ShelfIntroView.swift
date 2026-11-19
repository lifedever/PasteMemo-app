import SwiftUI

/// 贴边条介绍窗口的内容：顶部一段循环演示，下面是三张功能卡片、设置路径和按钮。
struct ShelfIntroView: View {
    static let width: CGFloat = 580

    let onTry: () -> Void
    let onKeep: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShelfIntroHero()
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
                // 标题栏透明，红绿灯压在这一截上
                .padding(.top, 34)

            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.tr("shelfIntro.title"))
                    .font(.system(size: 21, weight: .bold))
                Text(L10n.tr("shelfIntro.subtitle"))
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                HStack(alignment: .top, spacing: 10) {
                    tile(
                        symbol: "rectangle.topthird.inset.filled",
                        colors: [Color(red: 0.31, green: 0.55, blue: 1), Color(red: 0.15, green: 0.39, blue: 0.92)],
                        title: L10n.tr("shelfIntro.avoid.title"),
                        detail: L10n.tr("shelfIntro.avoid.detail")
                    )
                    tile(
                        symbol: "rectangle.split.3x1.fill",
                        colors: [Color(red: 1, green: 0.68, blue: 0.31), Color(red: 0.98, green: 0.45, blue: 0.09)],
                        title: L10n.tr("shelfIntro.cards.title"),
                        detail: L10n.tr("shelfIntro.cards.detail")
                    )
                    tile(
                        symbol: "list.number",
                        colors: [Color(red: 0.24, green: 0.86, blue: 0.52), Color(red: 0.09, green: 0.64, blue: 0.29)],
                        title: L10n.tr("shelfIntro.order.title"),
                        detail: L10n.tr("shelfIntro.order.detail")
                    )
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)

                settingsPath
                    .padding(.top, 18)
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)

            HStack(spacing: 10) {
                Spacer()
                Button(L10n.tr("shelfIntro.keep"), action: onKeep)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.tr("shelfIntro.try"), action: onTry)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 22)
        }
        .frame(width: Self.width)
    }

    private func tile(symbol: String, colors: [Color], title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .shadow(color: (colors.last ?? .clear).opacity(0.35), radius: 6, y: 3)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 10)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            colorScheme == .dark ? Color.white.opacity(0.05) : Color.white,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    /// 「以后在这里切换：设置 › 快捷面板 › 显示 › 快捷面板样式」，每一段都能点，点了打开设置
    private var settingsPath: some View {
        let segments = [
            L10n.tr("menu.settings"),
            L10n.tr("settings.quickPanel"),
            L10n.tr("settings.display"),
            L10n.tr("settings.quickPanelPresentation"),
        ]
        return HStack(spacing: 5) {
            Text(L10n.tr("shelfIntro.path"))
                .foregroundStyle(.secondary)
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                let isLast = index == segments.count - 1
                Button(action: onOpenSettings) {
                    Text(segment)
                        .fontWeight(isLast ? .semibold : .regular)
                        .foregroundStyle(isLast ? Color.accentColor : Color.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            isLast ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .font(.system(size: 12))
    }
}

// MARK: - 顶部演示动画

/// 循环演示两个场景：聊天窗口光标在下面，条从顶部滑下来；备忘录光标在上面，条从底部升上来。
/// 每轮里焦点在卡片间移动、勾上两张，收起后两段内容按顺序出现在输入框里。
/// 画面里不放文字（场景标签除外），哪种语言看都一样。
private struct ShelfIntroHero: View {
    private enum Scene { case chat, note }

    static let size = CGSize(width: ShelfIntroView.width - 40, height: 270)
    private static let cardWidths: [CGFloat] = [46, 78, 58, 44, 70, 60, 58]
    private static let shelfSize = CGSize(width: size.width - 28, height: 86)
    private static let chatFrame = CGRect(x: 70, y: 26, width: 300, height: 222)
    private static let noteFrame = CGRect(x: 160, y: 26, width: 300, height: 222)

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var scene: Scene = .chat
    @State private var shelfShown = false
    @State private var focusIndex: Int?
    @State private var picks: [Int] = []
    @State private var pastedCount = 0
    @State private var ringScale: CGFloat = 0.3
    @State private var ringOpacity: Double = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            wallpaper
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(width: Self.size.width, height: 12)
            chatWindow
                .opacity(scene == .chat ? 1 : 0)
                .animation(.easeInOut(duration: 0.35), value: scene)
            noteWindow
                .opacity(scene == .note ? 1 : 0)
                .animation(.easeInOut(duration: 0.35), value: scene)
            Circle()
                .strokeBorder(.white, lineWidth: 2)
                .frame(width: 30, height: 30)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)
                .position(caretPoint)
            shelf
            sceneTag
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .task {
            if reduceMotion {
                // 减弱动态效果：只摆出最后一帧
                shelfShown = true
                focusIndex = 6
                picks = [2, 6]
                return
            }
            await loop()
        }
    }

    // MARK: 时间线

    private func loop() async {
        while !Task.isCancelled {
            await play(.chat)
            await play(.note)
        }
    }

    private func play(_ next: Scene) async {
        // 换场景时条是隐藏的，位置直接跳到另一条边，不做动画
        scene = next
        shelfShown = false
        focusIndex = nil
        picks = []
        pastedCount = 0
        guard await pause(0.7) else { return }

        ringScale = 0.3
        ringOpacity = 1
        guard await pause(0.02) else { return }
        withAnimation(.easeOut(duration: 1)) {
            ringScale = 1.6
            ringOpacity = 0
        }
        guard await pause(0.5) else { return }

        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { shelfShown = true }
        guard await pause(0.8) else { return }

        let targets = next == .chat ? [2, 6] : [1, 5]
        for index in 0...(targets.last ?? 0) {
            withAnimation(.easeOut(duration: 0.15)) { focusIndex = index }
            if targets.contains(index) {
                guard await pause(0.25) else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { picks.append(index) }
            }
            guard await pause(0.3) else { return }
        }
        guard await pause(0.5) else { return }

        withAnimation(.easeIn(duration: 0.35)) { shelfShown = false }
        guard await pause(0.4) else { return }
        for _ in targets {
            withAnimation(.easeOut(duration: 0.3)) { pastedCount += 1 }
            guard await pause(0.28) else { return }
        }
        _ = await pause(1.6)
    }

    /// 等一段时间；窗口关了（任务被取消）返回 false，时间线就此停下
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }

    // MARK: 画面

    private var wallpaper: some View {
        ZStack {
            Color(red: 0.165, green: 0.184, blue: 0.353)
            RadialGradient(
                colors: [Color(red: 0.36, green: 0.49, blue: 1), .clear],
                center: UnitPoint(x: 0.18, y: 0.15), startRadius: 0, endRadius: 270
            )
            RadialGradient(
                colors: [Color(red: 0.71, green: 0.36, blue: 1), .clear],
                center: UnitPoint(x: 0.9, y: 0.9), startRadius: 0, endRadius: 260
            )
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var chatWindow: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.clear)
                .frame(height: 24)
                .overlay(alignment: .bottom) { Rectangle().fill(lineColor).frame(height: 0.5) }
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                bubble(0.6, mine: false)
                bubble(0.45, mine: true)
                bubble(0.52, mine: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            HStack(spacing: 4) {
                pastedChips(widths: [40, 26])
                caret
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .overlay(Capsule().strokeBorder(lineColor, lineWidth: 0.5))
            .padding([.horizontal, .bottom], 10)
        }
        .frame(width: Self.chatFrame.width, height: Self.chatFrame.height)
        .background(miniWindowFill, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .offset(x: Self.chatFrame.minX, y: Self.chatFrame.minY)
    }

    private var noteWindow: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.85)).frame(width: 90, height: 12)
            textLine(0.8).padding(.top, 12)
            HStack(spacing: 4) {
                pastedChips(widths: [34, 30])
                caret
            }
            .frame(height: 14)
            .padding(.top, 10)
            textLine(0.6).padding(.top, 14)
            textLine(0.7).padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .frame(width: Self.noteFrame.width, height: Self.noteFrame.height, alignment: .topLeading)
        .background(miniWindowFill, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .offset(x: Self.noteFrame.minX, y: Self.noteFrame.minY)
    }

    /// 光标所在的点，提示圈从这里扩散
    private var caretPoint: CGPoint {
        switch scene {
        case .chat: CGPoint(x: Self.chatFrame.minX + 22, y: Self.chatFrame.maxY - 24)
        case .note: CGPoint(x: Self.noteFrame.minX + 20, y: Self.noteFrame.minY + 71)
        }
    }

    private var shelf: some View {
        let shownY: CGFloat = scene == .chat ? 16 : Self.size.height - 10 - Self.shelfSize.height
        let hiddenOffset: CGFloat = scene == .chat ? -110 : 110
        return VStack(spacing: 6) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 3).fill(chipColor).frame(width: 70, height: 10)
                Spacer()
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(index == 0 ? Color.primary.opacity(0.35) : chipColor)
                            .frame(width: 20, height: 8)
                    }
                }
                Spacer()
                RoundedRectangle(cornerRadius: 3).fill(chipColor).frame(width: 40, height: 8)
            }
            .frame(height: 14)
            HStack(spacing: 6) {
                ForEach(Self.cardWidths.indices, id: \.self) { index in
                    miniCard(index)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: Self.shelfSize.width, height: Self.shelfSize.height)
        .background(shelfFill, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .offset(x: 14, y: shownY + (shelfShown ? 0 : hiddenOffset))
        .opacity(shelfShown ? 1 : 0)
    }

    private func miniCard(_ index: Int) -> some View {
        let isFocused = focusIndex == index
        return cardFace(index)
            .frame(width: Self.cardWidths[index], height: 54)
            .background(cardFill)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFocused ? Color.accentColor : lineColor, lineWidth: isFocused ? 2 : 0.5)
            )
            .overlay(alignment: .topTrailing) {
                if let order = picks.firstIndex(of: index) {
                    Text("\(order + 1)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 13, height: 13)
                        .background(Color.accentColor, in: Circle())
                        .padding(3)
                        .transition(.scale.combined(with: .opacity))
                }
            }
    }

    @ViewBuilder
    private func cardFace(_ index: Int) -> some View {
        switch index {
        case 0:
            Text("Aa")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        case 1:
            LinearGradient(
                colors: [Color(red: 1, green: 0.7, blue: 0.42), Color(red: 0.91, green: 0.38, blue: 0.35), Color(red: 0.23, green: 0.16, blue: 0.29)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case 3:
            Circle()
                .fill(Color(red: 0.23, green: 0.51, blue: 0.96))
                .frame(width: 20, height: 20)
                .shadow(color: Color(red: 0.23, green: 0.51, blue: 0.96).opacity(0.5), radius: 4, y: 2)
        case 4:
            VStack(alignment: .leading, spacing: 4) {
                codeLine(Color(red: 1, green: 0.48, blue: 0.7), 0.6)
                codeLine(Color(red: 0.62, green: 0.78, blue: 1), 0.8)
                codeLine(Color(red: 0.85, green: 0.79, blue: 0.49), 0.5)
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.12, green: 0.12, blue: 0.14))
        case 5:
            LinearGradient(
                colors: [Color(red: 0.91, green: 0.93, blue: 0.96), Color(red: 0.81, green: 0.85, blue: 0.9)],
                startPoint: .top, endPoint: .bottom
            )
        default:
            VStack(alignment: .leading, spacing: 4) {
                textLine(0.9)
                textLine(0.7)
                if index == 2 { textLine(0.8) }
            }
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var sceneTag: some View {
        Text(L10n.tr(scene == .chat ? "shelfIntro.scene.caretLow" : "shelfIntro.scene.caretHigh"))
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.35), in: Capsule())
            .frame(width: Self.size.width - 12, height: Self.size.height - 10, alignment: .bottomTrailing)
            .animation(.easeInOut(duration: 0.3), value: scene)
    }

    // MARK: 小部件

    private func bubble(_ fraction: CGFloat, mine: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(mine ? Color.accentColor : bubbleFill)
            .frame(width: (Self.chatFrame.width - 24) * fraction, height: 16)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    private func pastedChips(widths: [CGFloat]) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<min(pastedCount, widths.count), id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.3))
                    .frame(width: widths[index], height: 12)
                    .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
            }
        }
    }

    private var caret: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / 0.53).isMultiple(of: 2)
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 1.5, height: 12)
                .opacity(on ? 1 : 0)
        }
    }

    private func textLine(_ fraction: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.primary.opacity(0.28))
                .frame(width: proxy.size.width * fraction, height: 5)
        }
        .frame(height: 5)
    }

    private func codeLine(_ color: Color, _ fraction: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: proxy.size.width * fraction, height: 3.5)
        }
        .frame(height: 3.5)
    }

    private var isDark: Bool { colorScheme == .dark }
    private var miniWindowFill: Color { isDark ? Color(red: 0.15, green: 0.15, blue: 0.16) : .white }
    private var bubbleFill: Color { isDark ? Color(red: 0.22, green: 0.22, blue: 0.24) : Color(red: 0.91, green: 0.91, blue: 0.92) }
    private var lineColor: Color { Color.primary.opacity(0.1) }
    private var chipColor: Color { Color.primary.opacity(0.12) }
    private var cardFill: Color { isDark ? Color.white.opacity(0.08) : .white }
    private var shelfFill: Color {
        isDark ? Color(red: 0.16, green: 0.16, blue: 0.17).opacity(0.94) : Color(red: 0.965, green: 0.965, blue: 0.97).opacity(0.95)
    }
}
