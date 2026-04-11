import AppKit
import SwiftUI

private final class KeyableModalWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// SwiftUI-backed group editor window shown without blocking `NSApp.runModal(for:)`.
@MainActor
enum GroupEditorPanel {
    struct Result {
        let name: String
        let icon: String
    }

    private static var controller: GroupEditorPanelController?

    static func show(name: String = "", icon: String = "folder", onComplete: @escaping (Result?) -> Void) {
        controller?.closeWithoutCallback()
        let controller = GroupEditorPanelController(name: name, icon: icon, onComplete: onComplete)
        self.controller = controller
        controller.show()
    }

    static func dismissCurrent() {
        controller?.closeWithoutCallback()
        controller = nil
    }

    fileprivate static func clear(controller: GroupEditorPanelController) {
        if self.controller === controller {
            self.controller = nil
        }
    }
}

@MainActor
private final class GroupEditorPanelController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let viewModel: GroupEditorViewModel
    private var onComplete: ((GroupEditorPanel.Result?) -> Void)?
    private var didComplete = false

    init(name: String, icon: String, onComplete: @escaping (GroupEditorPanel.Result?) -> Void) {
        viewModel = GroupEditorViewModel(name: name, icon: icon)
        self.onComplete = onComplete

        let hosting = NSHostingController(rootView: GroupEditorView(viewModel: viewModel))

        window = KeyableModalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        super.init()

        window.title = name.isEmpty ? L10n.tr("action.newGroup") : L10n.tr("action.editGroup")
        window.level = .modalPanel
        window.isReleasedWhenClosed = false
        window.delegate = self

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 420))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let hostingView = hosting.view
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        container.layoutSubtreeIfNeeded()

        window.contentView = container
        window.center()

        viewModel.onDismiss = { [weak self] in
            self?.finish(with: nil)
        }
        viewModel.onConfirm = { [weak self] in
            guard let self else { return }
            let trimmed = self.viewModel.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.finish(with: GroupEditorPanel.Result(name: trimmed, icon: self.viewModel.selectedIcon))
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        finish(with: nil)
    }

    func closeWithoutCallback() {
        onComplete = nil
        didComplete = true
        if window.isVisible {
            NSApp.abortModal()
            window.close()
        }
        GroupEditorPanel.clear(controller: self)
    }

    private func finish(with result: GroupEditorPanel.Result?) {
        guard !didComplete else { return }
        didComplete = true

        let callback = onComplete
        onComplete = nil

        if window.isVisible {
            window.orderOut(nil)
            window.close()
        }

        GroupEditorPanel.clear(controller: self)
        callback?(result)
    }
}

@Observable
private final class GroupEditorViewModel {
    var name: String
    var selectedIcon: String
    var iconSearchText = ""
    var selectedCategory: IconCategory

    var onDismiss: (() -> Void)?
    var onConfirm: (() -> Void)?

    init(name: String, icon: String) {
        self.name = name
        self.selectedIcon = icon
        self.selectedCategory = IconCategory.all[0]
    }

    var filteredIcons: [String] {
        if !iconSearchText.isEmpty {
            let allIcons = IconCategory.all[0].icons
            return allIcons.filter { $0.localizedCaseInsensitiveContains(iconSearchText) }
        }
        return selectedCategory.icons
    }

    var isConfirmDisabled: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct IconCategory: Identifiable, Hashable {
    let id: String
    let label: String
    let icons: [String]

    static let all: [IconCategory] = {
        let cats = categories
        let allIcons = IconCategory(id: "all", label: "全部", icons: cats.flatMap(\.icons))
        return [allIcons] + cats
    }()

    private static let categories: [IconCategory] = [
        IconCategory(id: "file", label: "文件", icons: [
            "folder", "folder.fill", "tray", "tray.full", "tray.2",
            "archivebox", "archivebox.fill", "doc", "doc.fill", "doc.text", "doc.text.fill",
            "note.text", "list.bullet", "list.clipboard", "square.stack",
        ]),
        IconCategory(id: "mark", label: "标记", icons: [
            "bookmark", "bookmark.fill", "tag", "tag.fill",
            "star", "star.fill", "heart", "heart.fill",
            "flag", "flag.fill", "pin", "pin.fill",
            "rosette", "seal", "seal.fill", "bell", "bell.fill",
        ]),
        IconCategory(id: "work", label: "工作", icons: [
            "briefcase", "briefcase.fill", "building.2", "building.2.fill",
            "storefront", "storefront.fill", "house", "house.fill",
            "calendar", "clock", "timer", "hourglass",
            "chart.bar", "chart.bar.fill", "chart.pie", "chart.pie.fill",
            "chart.line.uptrend.xyaxis", "target", "scope",
        ]),
        IconCategory(id: "person", label: "人物", icons: [
            "person", "person.fill", "person.2", "person.2.fill",
            "person.crop.circle", "figure.walk", "figure.run",
            "graduationcap", "graduationcap.fill", "brain", "brain.head.profile",
        ]),
        IconCategory(id: "comm", label: "通信", icons: [
            "globe", "globe.americas", "link", "link.circle",
            "envelope", "envelope.fill", "phone", "phone.fill",
            "bubble.left", "bubble.left.fill", "bubble.right", "bubble.right.fill",
            "wifi", "network", "antenna.radiowaves.left.and.right",
        ]),
        IconCategory(id: "media", label: "媒体", icons: [
            "camera", "camera.fill", "photo", "photo.fill",
            "music.note", "music.note.list", "film", "video", "video.fill",
            "paintbrush", "paintbrush.fill", "paintpalette", "paintpalette.fill",
            "pencil", "pencil.circle", "eyedropper", "eyedropper.full",
            "highlighter", "theatermasks", "theatermasks.fill",
        ]),
        IconCategory(id: "tool", label: "工具", icons: [
            "wrench", "wrench.fill", "gear", "gearshape",
            "hammer", "hammer.fill", "screwdriver", "screwdriver.fill",
            "slider.horizontal.3", "tuningfork",
            "terminal", "terminal.fill", "chevron.left.forwardslash.chevron.right",
            "cpu", "memorychip", "externaldrive", "internaldrive",
        ]),
        IconCategory(id: "nature", label: "自然", icons: [
            "leaf", "leaf.fill", "flame", "flame.fill",
            "drop", "drop.fill", "bolt", "bolt.fill",
            "sun.max", "sun.max.fill", "moon", "moon.fill",
            "cloud", "cloud.fill", "snowflake", "wind",
            "sparkles", "sparkle",
        ]),
        IconCategory(id: "shop", label: "购物", icons: [
            "cart", "cart.fill", "bag", "bag.fill",
            "creditcard", "creditcard.fill", "banknote", "banknote.fill",
            "gift", "gift.fill", "dollarsign.circle", "dollarsign.circle.fill",
            "yensign.circle", "yensign.circle.fill",
        ]),
        IconCategory(id: "travel", label: "出行", icons: [
            "airplane", "car", "car.fill", "bicycle",
            "bus", "tram", "ferry",
            "map", "map.fill", "location", "location.fill",
            "compass.drawing", "binoculars", "suitcase", "suitcase.fill",
        ]),
        IconCategory(id: "fun", label: "娱乐", icons: [
            "gamecontroller", "gamecontroller.fill", "sportscourt",
            "trophy", "trophy.fill", "medal", "medal.fill",
            "puzzlepiece", "puzzlepiece.fill",
            "headphones", "guitars", "guitars.fill", "music.mic",
            "dice", "dice.fill",
        ]),
        IconCategory(id: "health", label: "安全", icons: [
            "heart.text.square", "cross.case", "cross.case.fill",
            "shield", "shield.fill", "lock", "lock.fill",
            "key", "key.fill", "hand.raised", "hand.raised.fill",
            "eye", "eye.fill", "faceid",
        ]),
        IconCategory(id: "food", label: "饮食", icons: [
            "cup.and.saucer", "cup.and.saucer.fill",
            "fork.knife", "birthday.cake",
            "wineglass", "wineglass.fill",
            "mug", "mug.fill", "waterbottle", "waterbottle.fill",
        ]),
    ]
}

private struct GroupEditorView: View {
    @Bindable var viewModel: GroupEditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            iconPickerSection
            Divider()
            footerSection
        }
        .frame(width: 380, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: viewModel.selectedIcon)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

            TextField(L10n.tr("automation.action.assignGroup.placeholder"), text: $viewModel.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
        }
        .padding(16)
    }

    private var iconPickerSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField("Search icons...", text: $viewModel.iconSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !viewModel.iconSearchText.isEmpty {
                    Button {
                        viewModel.iconSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.quaternary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if viewModel.iconSearchText.isEmpty {
                categoryTabs
                Divider()
            }

            iconGrid
        }
        .frame(maxHeight: .infinity)
    }

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(IconCategory.all) { category in
                    Button {
                        viewModel.selectedCategory = category
                    } label: {
                        Text(category.label)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                viewModel.selectedCategory == category ? Color.accentColor.opacity(0.15) : Color.clear,
                                in: Capsule()
                            )
                            .foregroundStyle(
                                viewModel.selectedCategory == category ? Color.accentColor : .secondary
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var iconGrid: some View {
        ScrollView {
            if viewModel.filteredIcons.isEmpty {
                ContentUnavailableView(
                    "No matching icons",
                    systemImage: "magnifyingglass",
                    description: Text("Try another keyword or category.")
                )
                .padding(.top, 32)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 8), spacing: 6) {
                    ForEach(viewModel.filteredIcons, id: \.self) { symbol in
                        Button {
                            viewModel.selectedIcon = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 16))
                                .frame(width: 36, height: 36)
                                .foregroundStyle(viewModel.selectedIcon == symbol ? .white : .primary)
                                .background(
                                    viewModel.selectedIcon == symbol ? Color.accentColor : Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(symbol)
                    }
                }
                .padding(12)
            }
        }
    }

    private var footerSection: some View {
        HStack {
            Spacer()
            Button(L10n.tr("action.cancel")) {
                viewModel.onDismiss?()
            }
            .keyboardShortcut(.cancelAction)

            Button(L10n.tr("action.confirm")) {
                viewModel.onConfirm?()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(viewModel.isConfirmDisabled)
        }
        .padding(12)
    }
}
