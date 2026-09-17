import AppKit
import Combine
import SwiftUI

/// 设置窗口的导航状态：当前页 + 看过的页面栈（标题栏那对箭头用）。
///
/// 从 View 里抽出来是因为窗口骨架改成了 AppKit 的 `NSSplitViewController`，
/// 侧边栏和详情区是两个各自独立的 `NSHostingController`，得有个共同的状态源。
@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var selection: SettingsCategory = .general {
        didSet {
            guard oldValue != selection else { return }
            recordHistory(selection)
            onSelectionChange?(selection)
        }
    }

    /// 选中页变化时的副作用（同步窗口标题）。由窗口骨架注入。
    var onSelectionChange: ((SettingsCategory) -> Void)?

    @Published private(set) var history: [SettingsCategory] = [.general]
    @Published private(set) var historyIndex = 0
    /// 箭头触发的切换不该再入栈，否则一路后退会把历史越堆越长。
    private var isNavigatingHistory = false

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    func goBack() {
        guard canGoBack else { return }
        isNavigatingHistory = true
        historyIndex -= 1
        selection = history[historyIndex]
    }

    func goForward() {
        guard canGoForward else { return }
        isNavigatingHistory = true
        historyIndex += 1
        selection = history[historyIndex]
    }

    /// 侧边栏点选时入栈。从中间位置跳到新页要先把「前进」那截截断——
    /// 浏览器和系统设置都是这个行为。
    private func recordHistory(_ category: SettingsCategory) {
        if isNavigatingHistory {
            isNavigatingHistory = false
            return
        }
        guard history.indices.contains(historyIndex), history[historyIndex] != category else { return }
        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(category)
        historyIndex = history.count - 1
    }
}

/// 设置窗口的骨架：AppKit 的 `NSSplitViewController`，两栏各装一个 SwiftUI 视图。
///
/// 为什么不用 SwiftUI 的 `NavigationSplitView`：它每轮 layout 都会把自己算的约束写回
/// 底层 split view item，我们设的固定宽度和「分隔线不可拖」当场被冲掉——试过
/// `.navigationSplitViewColumnWidth`（不生效）、AppKit 层设 min/max（宽度对了但还能拖）、
/// 包一层 split view delegate 拦拖拽（窗口直接建不起来）。把容器换成 AppKit 之后，
/// 约束就只有我们一家说了算，和系统设置是同一套做法。
///
/// `NSSplitViewItem(sidebarWithViewController:)` 还顺带给了系统级的侧边栏材质和通顶效果。
@MainActor
final class SettingsSplitViewController: NSSplitViewController {
    private let model: SettingsNavigationModel
    private var cancellable: AnyCancellable?

    /// 标题栏那对前进/后退。用 AppKit 的 NSSegmentedControl 而不是 SwiftUI `.toolbar`：
    /// 后者挂在 split view 里的 hosting controller 上，桥不到窗口标题栏（试过，按钮直接
    /// 不出现）。系统设置用的也是分段控件。
    private lazy var navigationSegments: NSSegmentedControl = {
        let back = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: L10n.tr("settings.nav.back"))
        let forward = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: L10n.tr("settings.nav.forward"))
        let control = NSSegmentedControl(
            images: [back, forward].compactMap { $0 },
            trackingMode: .momentary,
            target: self,
            action: #selector(navigate(_:))
        )
        control.segmentStyle = .separated
        control.setToolTip(L10n.tr("settings.nav.back"), forSegment: 0)
        control.setToolTip(L10n.tr("settings.nav.forward"), forSegment: 1)
        return control
    }()

    init(model: SettingsNavigationModel, sidebarWidth: CGFloat) {
        self.model = model
        super.init(nibName: nil, bundle: nil)

        let sidebar = NSHostingController(
            rootView: SettingsSidebar()
                .environmentObject(model)
                .localized()
        )
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        // min == max：AppKit 自己就把分隔线锁住了，这里没有别的层再来改它
        sidebarItem.minimumThickness = sidebarWidth
        sidebarItem.maximumThickness = sidebarWidth
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)

        let detail = NSHostingController(
            rootView: SettingsDetail()
                .environmentObject(model)
                .environmentObject(ClipboardManager.shared)
                .modelContainer(PasteMemoApp.sharedModelContainer)
                .localized()
        )
        addSplitViewItem(NSSplitViewItem(viewController: detail))

        // 历史栈一变就刷新箭头的可用状态
        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncNavigationState() }
        }
    }

    /// 必须在窗口显示**之前**调用。toolbar 一挂上去，窗口的 safe area 顶部就变了，
    /// 已显示的内容会跟着整体上移——看起来就是侧边栏的图标从下面窜上来一下。
    func installToolbar(on window: NSWindow) {
        guard window.toolbar == nil else { return }
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        syncNavigationState()
    }

    @objc private func navigate(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            model.goBack()
        } else {
            model.goForward()
        }
    }

    private func syncNavigationState() {
        navigationSegments.setEnabled(model.canGoBack, forSegment: 0)
        navigationSegments.setEnabled(model.canGoForward, forSegment: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension NSToolbarItem.Identifier {
    static let settingsNavigation = NSToolbarItem.Identifier("settingsNavigation")
}

extension SettingsSplitViewController: NSToolbarDelegate {
    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == .settingsNavigation else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = navigationSegments
        item.isNavigational = true
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.settingsNavigation]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.settingsNavigation]
    }
}
