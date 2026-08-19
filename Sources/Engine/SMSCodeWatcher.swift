import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Watches the Messages database (`~/Library/Messages/chat.db`) for incoming
/// SMS, runs `VerificationCodeExtractor` on new messages, and pushes extracted
/// codes onto the system clipboard.
///
/// Delivery contract (the feature's safety net): an extracted code is copied and
/// announced via notification; a message that *looks* like a code SMS but yields
/// no code is announced with its full text — a code SMS is never silently
/// dropped.
///
/// Reading chat.db requires Full Disk Access. The watcher polls every 2 seconds
/// (same idiom as AccessibilityMonitor / the clipboard poller); the tick doubles
/// as the permission retry while the user is granting FDA in System Settings.
/// All SQLite work runs on a private serial DispatchQueue — never on the Swift
/// Concurrency pool (v1.7.14 lesson: blocking calls pin cooperative threads).
final class SMSCodeWatcher: ObservableObject, @unchecked Sendable {
    static let shared = SMSCodeWatcher()

    static let enabledKey = "smsCodeCaptureEnabled"
    private static let lastRowIDKey = "smsCodeLastSeenRowID"

    /// Codes older than this are stale (already expired) — never notify them.
    /// Guards against replaying a backlog after the app was quit for a while.
    private static let FRESHNESS_WINDOW: TimeInterval = 10 * 60

    /// Main-thread published; drives the settings UI permission row.
    @Published private(set) var hasFullDiskAccess = false

    private let queue = DispatchQueue(label: "com.lifedever.pastememo.sms-watcher")
    // Queue-confined state ↓
    private var timer: DispatchSourceTimer?
    private var db: SQLiteConnection?

    private init() {}

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    private static var chatDBPath: String {
        NSHomeDirectory() + "/Library/Messages/chat.db"
    }

    // MARK: - Lifecycle

    /// Call from applicationDidFinishLaunching (must not hang launch) and from
    /// the settings toggle.
    func startIfEnabled() {
        guard Self.isEnabled else { return }
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.db?.close()
            self?.db = nil
        }
        publishAccess(false)
    }

    private func startOnQueue() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 2.0)
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
        DiagnosticLog.log("SMS watcher started")
    }

    // MARK: - Polling (queue-confined)

    private func tick() {
        guard Self.isEnabled else { return }
        guard ensureConnection() else { return }
        guard let db else { return }

        let lastRowID = UserDefaults.standard.integer(forKey: Self.lastRowIDKey)

        // First run: baseline to the current newest row, never replay history.
        guard lastRowID > 0 else {
            let maxID = db.queryInt("SELECT IFNULL(MAX(ROWID), 0) FROM message")
            UserDefaults.standard.set(max(maxID, 1), forKey: Self.lastRowIDKey)
            return
        }

        let cutoff = Int(Date().timeIntervalSince1970 - Self.FRESHNESS_WINDOW)
        // chat.db stores `date` as nanoseconds since 2001-01-01 (modern macOS).
        let rows = db.queryIntTextBlobRows(
            """
            SELECT ROWID, text, attributedBody FROM message
            WHERE ROWID > ? AND is_from_me = 0
              AND date/1000000000 + 978307200 > ?
            ORDER BY ROWID ASC LIMIT 50
            """,
            params: [lastRowID, cutoff]
        )

        if rows.isEmpty {
            // Advance past rows that exist but fell outside the freshness window,
            // so a long backlog isn't rescanned forever.
            let maxID = db.queryInt("SELECT IFNULL(MAX(ROWID), 0) FROM message")
            if maxID > lastRowID {
                UserDefaults.standard.set(maxID, forKey: Self.lastRowIDKey)
            }
            return
        }

        for (rowID, text, blob) in rows {
            UserDefaults.standard.set(rowID, forKey: Self.lastRowIDKey)
            // 14.6% of real incoming SMS have NULL `text` with the body living in
            // the attributedBody typedstream blob — decoding it is mandatory,
            // not an optimization (validated against 25k real messages).
            var body = text ?? ""
            if body.isEmpty, let blob {
                if let decoded = Self.decodeTypedStream(blob) {
                    body = decoded
                } else {
                    DiagnosticLog.log("SMS typedstream decode failed rowID=\(rowID) bytes=\(blob.count)")
                }
            }
            guard !body.isEmpty else { continue }
            let message = body
            DispatchQueue.main.async { Self.handle(message: message) }
        }
    }

    /// Opens (or re-opens) the read-only connection; publishes FDA status.
    private func ensureConnection() -> Bool {
        if db != nil { return true }
        guard let connection = SQLiteConnection(path: Self.chatDBPath, readOnly: true),
              connection.queryInt("SELECT count(*) FROM sqlite_master WHERE name='message'") > 0
        else {
            publishAccess(false)
            return false
        }
        db = connection
        publishAccess(true)
        DiagnosticLog.log("SMS watcher connected to chat.db")
        return true
    }

    private func publishAccess(_ granted: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hasFullDiskAccess != granted else { return }
            self.hasFullDiskAccess = granted
        }
    }

    // MARK: - Delivery (main thread)

    @MainActor
    private static func handle(message: String) {
        if let code = VerificationCodeExtractor.extract(from: message) {
            copyToClipboard(code)
            notify(
                title: L10n.tr("sms.notification.codeCopied", code),
                body: preview(of: message)
            )
        } else if VerificationCodeExtractor.isLikelyVerificationMessage(message) {
            // Extraction failed on a message that looks like a code SMS — degrade
            // to showing the full text instead of silently dropping it.
            notify(
                title: L10n.tr("sms.notification.fallbackTitle"),
                body: preview(of: message, limit: 160)
            )
        }
    }

    /// Same pattern as SetClipboardTool: write content + source marker, let the
    /// capture poller flow it into history. `captureAndSave` reads the marker and
    /// attributes the clip to the Messages app.
    @MainActor
    private static func copyToClipboard(_ code: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        pasteboard.setString("sms", forType: .smsCodeSource)
    }

    /// Localized display name of the Messages app ("信息" / "Messages" / …).
    /// Resolved from the system, never hardcoded — owner-name strings localize.
    static func messagesAppDisplayName() -> String {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.MobileSMS"
        ) else { return "Messages" }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private static func preview(of message: String, limit: Int = 80) -> String {
        let flat = message.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// Check permission → request if undetermined → add when authorized
    /// (mirrors ShortcutRunner.deliver — request and add must not race).
    private static func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let post = {
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString, content: content, trigger: nil
                )
                center.add(request)
            }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                post()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { post() }
                }
            default:
                break
            }
        }
    }

    // MARK: - typedstream decode

    /// `attributedBody` is an NSArchiver typedstream. NSUnarchiver is unavailable
    /// in Swift, so reach it via the ObjC runtime — validated with zero failures
    /// on 3610 real blobs.
    static func decodeTypedStream(_ data: Data) -> String? {
        guard let cls = NSClassFromString("NSUnarchiver") as? NSObject.Type,
              let obj = cls.perform(
                NSSelectorFromString("unarchiveObjectWithData:"), with: data as NSData
              )?.takeUnretainedValue()
        else { return nil }
        if let attributed = obj as? NSAttributedString { return attributed.string }
        return obj as? String
    }
}
