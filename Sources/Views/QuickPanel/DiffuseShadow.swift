import AppKit

/// 自绘窗口投影：系统窗口投影（`hasShadow`）贴着边缘有一圈深色接触线，浅色外观下
/// 看着就是一道黑边（主面板实测边缘像素 136/255，Raycast 同位置 160）。改成把投影画在
/// 一个只负责投影的透明子窗口里：一个只有 shadowPath 的 CALayer 让 CA 按窗口轮廓画
/// 散射，再用奇偶遮罩把窗口内部掏空，窗口底下保持透明、玻璃采样不到暗色。
/// ⌘K 卡片和主面板共用。
@MainActor
enum DiffuseShadow {
    /// 投影窗口比宿主窗口大出的一圈，必须装得下整个散射范围：半径 22 的散射约到 3 倍
    /// 处才消失，再加向下 8 的偏移，约 74pt。之前是 40，下沿散射被窗口边界硬裁出一条
    /// 平线。
    static let pad: CGFloat = 80

    static func makeView(size: NSSize, cornerRadius: CGFloat, contactLineInDark: Bool = false) -> NSView {
        DiffuseShadowView(size: size, cornerRadius: cornerRadius, contactLineInDark: contactLineInDark)
    }

    static func makePanel(level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = level
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

/// 散射投影 + 可选的深色接触线。
///
/// 深色外观下黑色散射叠在深色背景上几乎看不见，系统投影在深色下让窗口「有影子」的
/// 其实是贴着边缘那条 1px 黑线（黑底前实测 `14, 1, 43`，Raycast 同样）。开了
/// `contactLineInDark` 就在深色时沿宿主外沿补这条线，浅色不画（浅色下它就是那道黑边）。
private final class DiffuseShadowView: NSView {
    private let diffuse = CALayer()
    private let contactLine = CAShapeLayer()
    private let contactLineInDark: Bool

    init(size: NSSize, cornerRadius: CGFloat, contactLineInDark: Bool) {
        self.contactLineInDark = contactLineInDark
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        let hostRect = bounds.insetBy(dx: DiffuseShadow.pad, dy: DiffuseShadow.pad)
        let hostPath = CGPath(roundedRect: hostRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

        diffuse.frame = bounds
        diffuse.shadowPath = hostPath
        diffuse.shadowColor = NSColor.black.cgColor
        diffuse.shadowRadius = 22
        diffuse.shadowOffset = CGSize(width: 0, height: -8)
        let hole = CAShapeLayer()
        hole.frame = bounds
        let maskPath = CGMutablePath()
        maskPath.addRect(bounds)
        maskPath.addPath(hostPath)
        hole.path = maskPath
        hole.fillRule = .evenOdd
        diffuse.mask = hole
        layer?.addSublayer(diffuse)

        // 0.5pt 线、中心线再向外挪 0.25pt，整条线都落在宿主轮廓之外、不压到宿主内容。
        let lineWidth: CGFloat = 0.5
        let lineRect = hostRect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        contactLine.frame = bounds
        contactLine.path = CGPath(roundedRect: lineRect, cornerWidth: cornerRadius + lineWidth / 2, cornerHeight: cornerRadius + lineWidth / 2, transform: nil)
        contactLine.fillColor = nil
        contactLine.strokeColor = NSColor.black.withAlphaComponent(0.9).cgColor
        contactLine.lineWidth = lineWidth
        layer?.addSublayer(contactLine)

        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        diffuse.shadowOpacity = isDark ? 0.52 : 0.36
        contactLine.isHidden = !(isDark && contactLineInDark)
    }
}
