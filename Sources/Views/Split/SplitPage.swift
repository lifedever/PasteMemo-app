import AppKit
import SwiftUI

/// One split in progress: the clip's text (or files), the rule being tried, which pieces
/// are ticked. The quick panel's split page and the standalone split window both drive
/// one of these; they differ only in the header / footer around `SplitPageView`.
@MainActor
final class SplitSession: ObservableObject {

    enum Choice: CaseIterable {
        case auto, line, paragraph, numbered, delimiter, regex

        var titleKey: String {
            switch self {
            case .auto: "split.rule.auto"
            case .line: "split.rule.line"
            case .paragraph: "split.rule.paragraph"
            case .numbered: "split.rule.numbered"
            case .delimiter: "split.rule.delimiter"
            case .regex: "split.rule.regex"
            }
        }
    }

    private static let STRIP_KEY = "splitStripNumbering"
    private static let DELIMITER_KEY = "splitDelimiter"
    private static let CUSTOM_DELIMITER_KEY = "splitCustomDelimiter"
    private static let REGEX_KEY = "splitRegex"
    /// Texts longer than this (UTF-16 units) are split off the main thread.
    private static let MAIN_THREAD_LIMIT = 50_000

    let source: ClipSplit.Source

    @Published var choice: Choice = .auto {
        didSet { if choice != oldValue { recompute() } }
    }
    @Published var delimiter: ClipSplitter.Delimiter {
        didSet {
            guard delimiter != oldValue else { return }
            UserDefaults.standard.set(Self.storageValue(of: delimiter), forKey: Self.DELIMITER_KEY)
            recompute()
        }
    }
    /// What's typed in the「自定义」field; typing selects it.
    @Published var customDelimiter: String {
        didSet {
            guard customDelimiter != oldValue else { return }
            UserDefaults.standard.set(customDelimiter, forKey: Self.CUSTOM_DELIMITER_KEY)
            delimiter = .custom(customDelimiter)
        }
    }
    @Published var regex: String {
        didSet {
            guard regex != oldValue else { return }
            UserDefaults.standard.set(regex, forKey: Self.REGEX_KEY)
            recompute()
        }
    }
    @Published var stripNumbering: Bool {
        didSet {
            guard stripNumbering != oldValue else { return }
            UserDefaults.standard.set(stripNumbering, forKey: Self.STRIP_KEY)
            recompute()
        }
    }
    @Published private(set) var result = ClipSplitter.Result(pieces: [])
    /// Pieces the user unticked, by index into `result.pieces`.
    @Published private(set) var excluded: Set<Int> = []
    /// The row the keyboard is on (↑↓ moves it, space ticks it).
    @Published var focus = 0
    /// A regex run is still going; the previous result stays on screen meanwhile.
    @Published private(set) var isComputing = false

    private var running: CancelToken?

    init(source: ClipSplit.Source) {
        self.source = source
        let defaults = UserDefaults.standard
        stripNumbering = defaults.object(forKey: Self.STRIP_KEY) as? Bool ?? true
        let custom = defaults.string(forKey: Self.CUSTOM_DELIMITER_KEY) ?? ""
        customDelimiter = custom
        delimiter = Self.delimiter(fromStorage: defaults.string(forKey: Self.DELIMITER_KEY), custom: custom)
        regex = defaults.string(forKey: Self.REGEX_KEY) ?? ""
        recompute()
    }

    var isFiles: Bool {
        if case .files = source { return true }
        return false
    }

    var chosenPieces: [String] {
        result.pieces.enumerated().filter { !excluded.contains($0.offset) }.map(\.element)
    }

    var canConfirm: Bool {
        !isComputing && result.isSplittable && chosenPieces.count >= 2
    }

    /// What「自动」settled on, e.g.「按编号」/「顿号」.
    var autoResolvedTitle: String? {
        guard choice == .auto, let resolved = result.resolved else { return nil }
        switch resolved {
        case .line: return L10n.tr(Choice.line.titleKey)
        case .paragraph: return L10n.tr(Choice.paragraph.titleKey)
        case .numbered: return L10n.tr(Choice.numbered.titleKey)
        case .delimiter(let delimiter): return L10n.tr(delimiter.titleKey)
        }
    }

    func cycleChoice(forward: Bool) {
        guard !isFiles else { return }
        let all = Choice.allCases
        let index = all.firstIndex(of: choice) ?? 0
        choice = all[(index + (forward ? 1 : all.count - 1)) % all.count]
    }

    func moveFocus(by delta: Int) {
        guard !result.pieces.isEmpty else { return }
        focus = min(max(focus + delta, 0), result.pieces.count - 1)
    }

    func toggle(_ index: Int) {
        guard result.pieces.indices.contains(index) else { return }
        if excluded.contains(index) { excluded.remove(index) } else { excluded.insert(index) }
    }

    // MARK: -

    private var rule: ClipSplitter.Rule {
        switch choice {
        case .auto: .auto
        case .line: .line
        case .paragraph: .paragraph
        case .numbered: .numbered
        case .delimiter: .delimiter(delimiter)
        case .regex: .regex(regex)
        }
    }

    private func recompute() {
        running?.cancel()
        running = nil
        excluded = []
        focus = 0
        switch source {
        case .files(let paths):
            result = ClipSplitter.Result(pieces: paths)
            isComputing = false
        case .text(let text):
            let rule = rule
            let strip = stripNumbering
            let isRegex: Bool = { if case .regex = rule { return true } else { return false } }()
            guard isRegex || text.utf16.count > Self.MAIN_THREAD_LIMIT else {
                result = ClipSplitter.split(text, rule: rule, stripNumbering: strip)
                isComputing = false
                return
            }
            // A user pattern can backtrack for a long time, and a big text takes a moment
            // under any rule: keep those off the main thread, and drop a run as soon as the
            // rule changes again.
            let token = CancelToken()
            running = token
            isComputing = true
            Task.detached(priority: .userInitiated) { [weak self] in
                let result = ClipSplitter.split(text, rule: rule, stripNumbering: strip,
                                                isCancelled: { token.isCancelled })
                await MainActor.run {
                    guard let self, self.running === token else { return }
                    self.result = result
                    self.excluded = []
                    self.focus = 0
                    self.isComputing = false
                    self.running = nil
                }
            }
        }
    }

    private static func storageValue(of delimiter: ClipSplitter.Delimiter) -> String {
        switch delimiter {
        case .chineseComma: "chineseComma"
        case .comma: "comma"
        case .semicolon: "semicolon"
        case .pipe: "pipe"
        case .tab: "tab"
        case .custom: "custom"
        }
    }

    private static func delimiter(fromStorage value: String?, custom: String) -> ClipSplitter.Delimiter {
        switch value {
        case "comma": .comma
        case "semicolon": .semicolon
        case "pipe": .pipe
        case "tab": .tab
        case "custom" where !custom.isEmpty: .custom(custom)
        default: .chineseComma
        }
    }
}

private final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}

// MARK: - Keys

/// The split page's keys, the same wherever it's shown. ⌘↵ / ↵ split and go back to the
/// list, ⌘R starts Relay with the pieces, esc cancels; ⇥ / ⇧⇥ change the rule, ↑↓ move,
/// space ticks. Everything else (typing in the delimiter / regex field) passes through,
/// and nothing is taken while an input method is composing.
enum SplitPageKeys {
    enum Outcome {
        case passThrough, handled, confirm, relay, cancel
    }

    @MainActor
    static func handle(_ event: NSEvent, session: SplitSession) -> Outcome {
        let fieldEditor = event.window?.firstResponder as? NSTextView
        if fieldEditor?.hasMarkedText() == true { return .passThrough }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = flags.subtracting([.numericPad, .function]).isEmpty
        let cmdOnly = flags.subtracting([.numericPad, .function]) == .command
        switch Int(event.keyCode) {
        case 53:
            return .cancel
        case 36 where plain || cmdOnly, 76 where plain || cmdOnly:
            return .confirm
        case _ where cmdOnly && event.charactersIgnoringModifiers?.lowercased() == "r":
            // ⌘R by character, not key position, so it follows the keyboard layout
            return session.isFiles ? .handled : .relay
        case 48: // ⇥
            session.cycleChoice(forward: !flags.contains(.shift))
            return .handled
        case 125 where !flags.contains(.command): // ↓
            session.moveFocus(by: 1)
            return .handled
        case 126 where !flags.contains(.command): // ↑
            session.moveFocus(by: -1)
            return .handled
        case 49 where plain && fieldEditor == nil: // space
            session.toggle(session.focus)
            return .handled
        default:
            return .passThrough
        }
    }
}

// MARK: - View

/// The split page's content card: rule picker on top, the pieces below. Same card as the
/// editor's (`ClipTextEditor`), so ⌘E and「拆分」read as one family of pages.
struct SplitPageView: View {
    @ObservedObject var session: SplitSession
    var fontSize: CGFloat = 13

    private enum Field { case custom, regex }
    @FocusState private var field: Field?

    var body: some View {
        VStack(spacing: 0) {
            if !session.isFiles {
                rulesBar
                if session.choice == .delimiter { delimiterRow }
                if session.choice == .regex { regexRow }
                Divider()
                    .opacity(0.6)
                    .padding(.horizontal, 10)
            }
            pieces
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.08))
        )
        .onChange(of: session.choice) {
            // Leaving the regex / delimiter rule hands the keys back to the page (⇥ / ↑↓ /
            // space); the regex field takes them itself when it appears.
            if session.choice != .regex { field = nil }
        }
    }

    // MARK: Rules

    private var rulesBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(SplitSession.Choice.allCases, id: \.self) { choice in
                    ruleButton(choice)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))

            Text("⇥")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .frame(minHeight: 16)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
                .help(L10n.tr("split.switchRule"))

            Spacer(minLength: 8)

            if session.result.canStripNumbering {
                Toggle(L10n.tr("split.stripNumbering"), isOn: $session.stripNumbering)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func ruleButton(_ choice: SplitSession.Choice) -> some View {
        let selected = session.choice == choice
        return Button {
            session.choice = choice
        } label: {
            HStack(spacing: 3) {
                Text(L10n.tr(choice.titleKey))
                if choice == .auto, let resolved = session.autoResolvedTitle {
                    Text("· \(resolved)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.12))
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var delimiterRow: some View {
        HStack(spacing: 6) {
            ForEach(ClipSplitter.Delimiter.presets, id: \.self) { delimiter in
                let selected = session.delimiter == delimiter
                Button {
                    session.delimiter = delimiter
                    field = nil
                } label: {
                    Text(L10n.tr(delimiter.titleKey))
                        .font(.system(size: 11.5))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(selected ? 0.14 : 0.05))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            TextField(L10n.tr("split.delimiter.custom"), text: $session.customDelimiter)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 110)
                .focused($field, equals: .custom)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var regexRow: some View {
        HStack(spacing: 8) {
            TextField(L10n.tr("split.regex.placeholder"), text: $session.regex)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($field, equals: .regex)
                // Picking「正则」puts the cursor here; the field only exists from now on, so
                // focusing it from the choice change alone can land before it does.
                .onAppear { field = .regex }
                .overlay {
                    if session.result.invalidPattern {
                        RoundedRectangle(cornerRadius: 5).stroke(Color.red.opacity(0.7), lineWidth: 1)
                    }
                }
            Text(L10n.tr(session.result.invalidPattern ? "split.regex.invalid" : "split.regex.hint"))
                .font(.system(size: 11))
                .foregroundStyle(session.result.invalidPattern ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: Pieces

    @ViewBuilder
    private var pieces: some View {
        let result = session.result
        if result.invalidPattern {
            emptyState(L10n.tr("split.regex.invalid"))
        } else if result.isOverLimit {
            emptyState(L10n.tr("split.tooMany", ClipSplitter.MAX_PIECES))
        } else if result.pieces.count < 2 {
            if session.isComputing {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState(L10n.tr("split.single"))
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(result.pieces.enumerated()), id: \.offset) { index, piece in
                            SplitPieceRow(
                                index: index,
                                text: piece,
                                isOn: !session.excluded.contains(index),
                                isFocused: session.focus == index,
                                fontSize: fontSize
                            )
                            .id(index)
                            .onTapGesture {
                                session.focus = index
                                session.toggle(index)
                            }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: session.focus) {
                    proxy.scrollTo(session.focus)
                }
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SplitPieceRow: View {
    let index: Int
    let text: String
    let isOn: Bool
    let isFocused: Bool
    let fontSize: CGFloat
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .padding(.top, 1)
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 18, alignment: .trailing)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: fontSize))
                .lineSpacing(2)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(isOn ? 1 : 0.4)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isFocused ? 0.08 : (isHovered ? 0.04 : 0)))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
