import Foundation
import AppKit
@preconcurrency import UserNotifications

enum ShortcutRunnerError: LocalizedError {
    case shortcutsCLINotFound
    case nonZeroExit(code: Int32, stderr: String)
    case timeout
    case emptyName

    var errorDescription: String? {
        switch self {
        case .shortcutsCLINotFound:
            return "/usr/bin/shortcuts not found (requires macOS 12+)."
        case .nonZeroExit(let code, let stderr):
            return "Shortcut exited \(code): \(stderr)"
        case .timeout:
            return "Shortcut timed out."
        case .emptyName:
            return "Shortcut name is empty."
        }
    }
}

/// Runs a macOS Shortcut via `/usr/bin/shortcuts run`, feeding a ClipItem-worth
/// of data in and returning the Shortcut's output bytes.
enum ShortcutRunner {

    /// Result bytes plus a best-effort guess at whether they're text or binary.
    struct Output: Sendable {
        let data: Data
        let isLikelyText: Bool

        var text: String? {
            guard isLikelyText, let s = String(data: data, encoding: .utf8) else { return nil }
            // Shortcut stdout typically ends with a trailing newline from `echo`.
            // Trim whitespace so the value is clean when pasted into Markdown etc.
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static let shortcutsPath = "/usr/bin/shortcuts"
    static let defaultTimeoutSeconds: Double = 30

    /// Run a named Shortcut. Input is picked based on the clip:
    /// - `.image` with `imageData` → temp PNG passed via `--input-path`
    /// - `.file/.video/...` → the content string (path) passed via `--input-path`
    /// - anything else → `content` piped on stdin
    @MainActor
    static func run(
        name: String,
        content: String,
        imageData: Data?,
        contentType: ClipContentType,
        timeoutSeconds: Double = defaultTimeoutSeconds
    ) async throws -> Output {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ShortcutRunnerError.emptyName }
        guard FileManager.default.isExecutableFile(atPath: shortcutsPath) else {
            throw ShortcutRunnerError.shortcutsCLINotFound
        }

        let inputContext = try prepareInput(
            content: content, imageData: imageData, contentType: contentType
        )
        defer {
            if let url = inputContext.tempURLToClean {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pastememo-shortcut-out-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        return try await Task.detached(priority: .userInitiated) {
            var args: [String] = ["run", trimmedName]
            if let inPath = inputContext.inputPath {
                args += ["--input-path", inPath]
            }
            args += ["--output-path", outputURL.path]

            let process = Process()
            process.executableURL = URL(fileURLWithPath: shortcutsPath)
            process.arguments = args

            let stdin = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardError = stderr
            process.standardOutput = Pipe()  // drain to avoid backpressure

            try process.run()

            if let stdinData = inputContext.stdinData {
                try? stdin.fileHandleForWriting.write(contentsOf: stdinData)
            }
            try? stdin.fileHandleForWriting.close()

            // Timeout: kill the process if it runs too long.
            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                if process.isRunning { process.terminate() }
            }

            process.waitUntilExit()
            timeoutTask.cancel()

            let status = process.terminationStatus
            let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            guard status == 0 else {
                let errText = String(data: errData, encoding: .utf8) ?? ""
                if process.terminationReason == .uncaughtSignal {
                    throw ShortcutRunnerError.timeout
                }
                throw ShortcutRunnerError.nonZeroExit(code: status, stderr: errText)
            }

            let data = (try? Data(contentsOf: outputURL)) ?? Data()
            return Output(data: data, isLikelyText: data.looksLikeText)
        }.value
    }

    /// Fetch the list of user-defined Shortcuts. Used for a picker in the rule
    /// editor. Returns an empty array if the CLI fails or isn't available.
    static func listAvailableShortcuts(timeoutSeconds: Double = 5) async -> [String] {
        guard FileManager.default.isExecutableFile(atPath: shortcutsPath) else { return [] }

        return await Task.detached(priority: .userInitiated) { () -> [String] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shortcutsPath)
            process.arguments = ["list"]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()

            guard (try? process.run()) != nil else { return [] }

            let timeoutTask = Task {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                if process.isRunning { process.terminate() }
            }
            process.waitUntilExit()
            timeoutTask.cancel()

            guard process.terminationStatus == 0 else { return [] }
            let data = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
            return (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }.value
    }

    /// Opens the named Shortcut in Shortcuts.app for editing.
    @MainActor
    static func openShortcutInApp(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
              ),
              let url = URL(string: "shortcuts://open-shortcut?name=\(encoded)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Input preparation

    private struct InputContext: Sendable {
        let inputPath: String?
        let stdinData: Data?
        let tempURLToClean: URL?
    }

    private static func prepareInput(
        content: String,
        imageData: Data?,
        contentType: ClipContentType
    ) throws -> InputContext {
        switch contentType {
        case .image:
            // Prefer the clip's original file path when available — imageData
            // is PNG-reencoded at capture time, which blows up JPEG sizes
            // 5-10x (14MB JPEG → ~80MB PNG) and defeats the point of pipes
            // like image compression.
            if content != "[Image]" {
                let firstPath = content
                    .components(separatedBy: "\n")
                    .first { !$0.isEmpty }
                if let path = firstPath, FileManager.default.fileExists(atPath: path) {
                    return InputContext(inputPath: path, stdinData: nil, tempURLToClean: nil)
                }
            }
            // Fallback: no usable file path, dump the captured image bytes.
            // Detect real format from magic bytes — don't trust a hardcoded
            // `.png` extension or scripts using libpng will choke on JPEGs.
            if let imageData, !imageData.isEmpty {
                let ext = imageFileExtension(from: imageData)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("pastememo-shortcut-in-\(UUID().uuidString).\(ext)")
                try imageData.write(to: url)
                return InputContext(
                    inputPath: url.path, stdinData: nil, tempURLToClean: url
                )
            }
            // Image clip without imageData (file-path-based image): fall through to path.
            fallthrough
        case .file, .video, .audio, .document, .archive, .application:
            // Content is a file path (or newline-joined paths). Use the first path.
            let firstPath = content
                .components(separatedBy: "\n")
                .first { !$0.isEmpty }
            if let path = firstPath, FileManager.default.fileExists(atPath: path) {
                return InputContext(inputPath: path, stdinData: nil, tempURLToClean: nil)
            }
            // No usable file path → pipe content as text instead of failing.
            return InputContext(
                inputPath: nil, stdinData: content.data(using: .utf8), tempURLToClean: nil
            )
        case .text, .code, .link, .color, .email, .phone, .mixed:
            return InputContext(
                inputPath: nil, stdinData: content.data(using: .utf8), tempURLToClean: nil
            )
        }
    }

    /// Sniff the real image format from the first bytes (PNG / JPEG / GIF /
    /// WebP / HEIC). Falls back to `png` so callers still get *some* extension.
    private static func imageFileExtension(from data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 3 else { return "png" }
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if bytes.count >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50
            && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "png"
        }
        // JPEG: FF D8 FF
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return "jpg"
        }
        // GIF: "GIF8"
        if bytes.count >= 4 && bytes[0] == 0x47 && bytes[1] == 0x49
            && bytes[2] == 0x46 && bytes[3] == 0x38 {
            return "gif"
        }
        // WebP: "RIFF" ... "WEBP"
        if bytes.count >= 12
            && Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46]
            && Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return "webp"
        }
        // HEIC: ftyp box at offset 4, brand "heic" / "heix" / "mif1" / "msf1"
        if bytes.count >= 12
            && Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] {
            let brand = String(bytes: Array(bytes[8..<12]), encoding: .ascii) ?? ""
            if ["heic", "heix", "hevc", "mif1", "msf1"].contains(brand) {
                return "heic"
            }
        }
        return "png"
    }
}

// MARK: - Notifier
//
// runShortcut is a background operation (compress+upload can take seconds and
// the user often switches apps while it runs), so success and failure are
// delivered as system notifications rather than an in-window toast or blocking
// alert. Requires Notifications permission — requested lazily on first use.

enum ShortcutNotifier {
    @MainActor
    static func showSuccess(ruleName: String) {
        let content = UNMutableNotificationContent()
        content.title = ruleName.isEmpty
            ? L10n.tr("automation.notification.title")
            : ruleName
        content.body = L10n.tr("automation.applied")
        content.sound = .default
        deliver(content: content)
    }

    @MainActor
    static func showFailure(ruleName: String, error: Error) {
        let content = UNMutableNotificationContent()
        let title = L10n.tr("automation.action.runShortcut.failed")
        content.title = ruleName.isEmpty ? title : "\(title): \(ruleName)"
        let message = error.localizedDescription
        content.body = message.count > 240 ? String(message.prefix(240)) + "…" : message
        content.sound = .defaultCritical
        deliver(content: content) { delivered in
            // Fall back to an alert when the user hasn't allowed notifications —
            // failures shouldn't silently disappear.
            if !delivered {
                Task { @MainActor in
                    let alert = NSAlert()
                    alert.messageText = content.title
                    alert.informativeText = content.body
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    /// Check permission → request if undetermined → add when authorized.
    /// Running `requestAuthorization` and `add` in parallel drops the first
    /// notification, so we gate `add` on the async settings callback.
    private static func deliver(
        content: UNNotificationContent,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        guard Bundle.main.bundleIdentifier != nil else {
            completion?(false); return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                post(content, via: center, completion: completion)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        post(content, via: center, completion: completion)
                    } else {
                        completion?(false)
                    }
                }
            case .denied:
                completion?(false)
            @unknown default:
                completion?(false)
            }
        }
    }

    private static func post(
        _ content: UNNotificationContent,
        via center: UNUserNotificationCenter,
        completion: (@Sendable (Bool) -> Void)?
    ) {
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        center.add(request) { error in
            completion?(error == nil)
        }
    }
}

// Legacy alias — kept so existing call sites compile. Routes failure through
// the system notification path.
enum ShortcutErrorNotifier {
    @MainActor
    static func show(name: String, error: Error) {
        ShortcutNotifier.showFailure(ruleName: name, error: error)
    }
}

// MARK: - Text/binary heuristic

private extension Data {
    /// Best-effort: treat as text if it decodes as UTF-8 and contains no
    /// control bytes outside common whitespace.
    var looksLikeText: Bool {
        guard !isEmpty else { return true }
        guard let _ = String(data: self, encoding: .utf8) else { return false }
        // Look at up to 4KB — bail out early on obviously-binary signatures.
        let sample = prefix(4096)
        for byte in sample {
            if byte == 0 { return false }
            // Allow tab / LF / CR; reject other control bytes
            if byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D {
                return false
            }
        }
        return true
    }
}
