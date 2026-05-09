import AppKit
import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var latestVersion: String?
    @Published var updateAvailable = false
    @Published var releaseNotes: String?
    @Published var downloadURL: URL?
    @Published var isChecking = false
    /// True iff `latestVersion` was selected from the beta channel.
    /// Drives the BETA badge in the update dialog.
    @Published var isBetaUpdate = false

    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var downloadComplete = false
    @Published var downloadedFileURL: URL?

    @Published var showUpdateDialog = false

    private let latestJsonURL = "https://www.lifedever.com/PasteMemo/latest.json"
    private let repoOwner = "lifedever"
    private let repoName = "PasteMemo-app"
    private let giteeRepo = "lifedever/pastememo"

    private var downloadTask: URLSessionDownloadTask?
    private var downloadDelegate: DownloadDelegate?
    private var githubFallbackURL: URL?
    private var periodicTimer: Timer?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var isDev: Bool { DevDataImporter.isDevBuild }

    /// Production builds always hit the canonical CDN feed. Dev builds may
    /// override the URL via UserDefaults so we can point at a locally-hosted
    /// mock `latest.json` and test channel switching, beta dialog rendering,
    /// edge cases, etc. without polluting production:
    ///
    ///     defaults write com.lifedever.pastememo.dev \
    ///         devLatestJsonOverride "http://localhost:8000/latest-mock.json"
    ///     defaults delete com.lifedever.pastememo.dev devLatestJsonOverride
    private var resolvedLatestJsonURL: String {
        if isDev,
           let override = UserDefaults.standard.string(forKey: "devLatestJsonOverride"),
           !override.isEmpty {
            return override
        }
        return latestJsonURL
    }

    private init() {}

    // MARK: - Check

    func checkForUpdates(userInitiated: Bool = false) async {
        guard userInitiated || !isDev else { return }
        if !userInitiated {
            guard UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true else { return }
        }

        isChecking = true
        defer { isChecking = false }

        // Primary: static JSON (no rate limit)
        var remoteVersion: String?
        var notes: String?
        var archDownloadURL: URL?
        // Reset before each check so a stale beta flag from a previous run
        // doesn't bleed into a stable-channel result.
        isBetaUpdate = false

        if let info = await fetchLatestJSON() {
            // Pick stable or beta channel. Beta wins only when the user has
            // opted in AND beta is strictly newer than the stable release —
            // so once a beta is promoted to stable, beta-channel users
            // automatically fall back to the stable entry and get the upgrade.
            let useBeta = UserDefaults.standard.bool(forKey: "includeBetaChannel")
            let channel = pickChannel(info: info, useBeta: useBeta)
            isBetaUpdate = channel.isBeta

            remoteVersion = channel.version
            let zhNotes = channel.notesZh ?? ""
            let enNotes = channel.notesEn ?? ""
            let lang = LanguageManager.shared.current
            let isChinese = lang.hasPrefix("zh")
            notes = isChinese ? (zhNotes.isEmpty ? enNotes : zhNotes) : (enNotes.isEmpty ? zhNotes : enNotes)
            let arch = currentArch()
            // Prefer checksums (has size/sha256), fall back to downloads
            let entry = channel.checksums?[arch] ?? channel.downloads[arch]
            archDownloadURL = entry.flatMap { URL(string: $0.url) }
            if let fileSize = entry?.size {
                totalBytes = Int64(fileSize)
            }

        }

        // Fallback: Gitee / GitHub API (for old releases or if JSON unavailable)
        if remoteVersion == nil {
            var release = await fetchLatestRelease(
                from: "https://gitee.com/api/v5/repos/\(giteeRepo)/releases"
            )
            if release == nil {
                release = await fetchLatestRelease(
                    from: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases"
                )
            }
            if let release {
                remoteVersion = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                notes = release.body
                let arch = currentArch()
                let dmgName = "\(repoName)-\(remoteVersion!)-\(arch).dmg"
                archDownloadURL = URL(string: "https://gitee.com/\(giteeRepo)/releases/download/v\(remoteVersion!)/\(dmgName)")
                if let dmgAsset = release.assets?.first(where: { $0.name.contains(arch) && $0.name.hasSuffix(".dmg") }) {
                    totalBytes = Int64(dmgAsset.size ?? 0)
                }
            }
        }

        guard let remoteVersion else {
            if userInitiated { showCheckFailedAlert() }
            return
        }

        latestVersion = remoteVersion
        releaseNotes = notes

        let arch = currentArch()
        let dmgName = "\(repoName)-\(remoteVersion)-\(arch).dmg"
        githubFallbackURL = URL(string: "https://www.lifedever.com/PasteMemo/downloads/\(dmgName)")
        downloadURL = archDownloadURL ?? githubFallbackURL

        let skippedVersion = UserDefaults.standard.string(forKey: "skippedVersion")
        if !userInitiated && remoteVersion == skippedVersion {
            updateAvailable = false
        } else {
            updateAvailable = isNewer(remote: remoteVersion, current: currentVersion)
        }

        UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")

        if updateAvailable {
            showUpdateWindow(updater: self)
        } else if userInitiated {
            showUpToDateAlert()
        }
    }

    // MARK: - Download

    func downloadUpdate() {
        guard let url = downloadURL else { return }
        startDownload(from: url)
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        downloadComplete = false
    }

    func skipVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: "skippedVersion")
        updateAvailable = false
        showUpdateDialog = false
    }

    // MARK: - Install

    func installAndRestart() {
        guard let fileURL = downloadedFileURL else { return }

        let mountResult = mountDMG(at: fileURL.path)
        guard let mountPoint = mountResult else {
            showDMGErrorAlert()
            return
        }

        let sourceApp = "\(mountPoint)/PasteMemo.app"
        guard FileManager.default.fileExists(atPath: sourceApp) else {
            detachDMG(mountPoint)
            showDMGErrorAlert()
            return
        }

        let destApp = Bundle.main.bundlePath
        // Glob every *.bundle so future SwiftPM deps don't silently leave stale
        // or missing resource bundles behind (see Bundle.module SIGTRAP: issue #38).
        let script = """
        #!/bin/bash
        sleep 2
        # Replace contents only, preserve app bundle identity for accessibility permissions
        rm -rf "\(destApp)/Contents/MacOS"
        rm -rf "\(destApp)/Contents/Resources"
        rm -rf "\(destApp)"/*.bundle
        cp -R "\(sourceApp)/Contents/MacOS" "\(destApp)/Contents/MacOS"
        cp -R "\(sourceApp)/Contents/Resources" "\(destApp)/Contents/Resources"
        cp "\(sourceApp)/Contents/Info.plist" "\(destApp)/Contents/Info.plist"
        for b in "\(sourceApp)"/*.bundle; do
            [ -d "$b" ] && cp -R "$b" "\(destApp)/"
        done
        hdiutil detach "\(mountPoint)" -quiet 2>/dev/null
        open "\(destApp)"
        rm -f "$0"
        """

        do {
            let scriptPath = NSTemporaryDirectory() + "pastememo_update.sh"
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptPath]
            try process.run()

            AppDelegate.shouldReallyQuit = true
            NSApp.terminate(nil)
        } catch {
            detachDMG(mountPoint)
            NSWorkspace.shared.open(fileURL)
        }
    }

    // MARK: - Periodic

    func startPeriodicChecks() {
        periodicTimer?.invalidate()
        guard !isDev else { return }
        guard UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true else { return }

        let hours = max(UserDefaults.standard.integer(forKey: "updateCheckInterval"), 6)

        periodicTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(hours * 3600), repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForUpdates()
            }
        }
    }

    func stopPeriodicChecks() {
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    // MARK: - Private

    private func startDownload(from url: URL) {
        isDownloading = true
        downloadProgress = 0
        downloadedBytes = 0
        downloadComplete = false

        let delegate = DownloadDelegate(
            onProgress: { [weak self] progress, received, total in
                Task { @MainActor in
                    self?.downloadProgress = progress
                    self?.downloadedBytes = received
                    self?.totalBytes = total
                }
            },
            onComplete: { [weak self] fileURL in
                Task { @MainActor in
                    self?.downloadComplete = true
                    self?.downloadedFileURL = fileURL
                    self?.isDownloading = false
                }
            },
            onError: { [weak self] errorMessage in
                Task { @MainActor in
                    guard let self else { return }
                    if let fallback = self.githubFallbackURL, url != fallback {
                        self.githubFallbackURL = nil
                        self.startDownload(from: fallback)
                    } else {
                        self.isDownloading = false
                        self.downloadComplete = false
                        self.downloadProgress = 0
                        self.showDownloadErrorAlert(errorMessage)
                    }
                }
            }
        )
        self.downloadDelegate = delegate

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    private func fetchLatestJSON() async -> LatestInfo? {
        guard let url = URL(string: resolvedLatestJsonURL) else { return nil }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(LatestInfo.self, from: data)
        } catch {
            return nil
        }
    }

    private func fetchLatestRelease(from urlString: String) async -> ReleaseInfo? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }
            let releases = try JSONDecoder().decode([ReleaseInfo].self, from: data)
            // Defense in depth: never let the fallback path nominate a
            // pre-release. Beta builds aren't supposed to ship via GitHub /
            // Gitee public releases at all, but if one ever leaks through
            // we don't want the older clients (whose `isNewer` predates the
            // SemVer fix) to interpret a `1.7.0-beta.1` tag as a stable
            // upgrade target.
            let stable = releases.filter { $0.prerelease != true }
            // Gitee returns oldest first, GitHub returns newest first — pick highest version
            return stable.max { lhs, rhs in
                let l = lhs.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let r = rhs.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                return isNewer(remote: r, current: l)
            }
        } catch {
            return nil
        }
    }

    private func currentArch() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    private func isNewer(remote: String, current: String) -> Bool {
        SemanticVersion.isNewer(remote: remote, current: current)
    }

    private func mountDMG(at path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", path, "-nobrowse", "-noverify"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = output.components(separatedBy: "\n").first(where: { $0.contains("/Volumes/") }),
              let range = line.range(of: "/Volumes/") else { return nil }
        return String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
    }

    private func detachDMG(_ mountPoint: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-quiet"]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Alerts

    private func showCheckFailedAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("update.check_failed")
        alert.informativeText = L10n.tr("update.check_failed.hint")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("update.check_failed.github"))
        alert.addButton(withTitle: L10n.tr("update.check_failed.gitee"))
        alert.addButton(withTitle: L10n.tr("update.check_failed.cancel"))
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://github.com/lifedever/PasteMemo-app/releases")!)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://gitee.com/lifedever/pastememo/releases")!)
        default:
            break
        }
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("update.no_updates")
        alert.informativeText = L10n.tr("update.no_updates.message", currentVersion)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.tr("action.confirm"))
        alert.runModal()
    }

    private func showDownloadErrorAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("update.download_error")
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: L10n.tr("action.confirm"))
        alert.runModal()
    }

    private func showDMGErrorAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("update.dmg_error")
        alert.informativeText = L10n.tr("update.dmg_error.message")
        alert.alertStyle = .critical
        alert.addButton(withTitle: L10n.tr("action.confirm"))
        alert.runModal()

        downloadComplete = false
        downloadedFileURL = nil
        isDownloading = false
        downloadProgress = 0
    }
}

// MARK: - Models

// Exposed at module scope (rather than file-private) so unit tests can verify
// JSON decoding and channel-selection behavior end to end.
struct LatestInfo: Codable {
    let version: String
    let notesZh: String?
    let notesEn: String?
    let downloads: [String: DownloadEntry]
    let checksums: [String: DownloadEntry]?
    let pro: String?
    let beta: BetaChannel?

    enum CodingKeys: String, CodingKey {
        case version
        case notesZh = "notes_zh"
        case notesEn = "notes_en"
        case downloads
        case checksums
        case pro
        case beta
    }

    struct DownloadEntry: Codable {
        let url: String
        let size: Int?
        let sha256: String?

        init(from decoder: Decoder) throws {
            // Support both old format ("arm64": "url") and new format ("arm64": { "url": ... })
            if let plainURL = try? decoder.singleValueContainer().decode(String.self) {
                url = plainURL
                size = nil
                sha256 = nil
            } else {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                url = try container.decode(String.self, forKey: .url)
                size = try container.decodeIfPresent(Int.self, forKey: .size)
                sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case url, size, sha256
        }
    }

    struct BetaChannel: Codable {
        let version: String
        let notesZh: String?
        let notesEn: String?
        let downloads: [String: DownloadEntry]
        let checksums: [String: DownloadEntry]?

        enum CodingKeys: String, CodingKey {
            case version, downloads, checksums
            case notesZh = "notes_zh"
            case notesEn = "notes_en"
        }
    }
}

/// A channel-agnostic projection of either the stable entry or the beta entry
/// inside `LatestInfo`. Lets `checkForUpdates` consume the same shape regardless
/// of which channel won.
struct ChannelView: Equatable {
    let version: String
    let notesZh: String?
    let notesEn: String?
    let downloads: [String: LatestInfo.DownloadEntry]
    let checksums: [String: LatestInfo.DownloadEntry]?
    let isBeta: Bool

    static func == (lhs: ChannelView, rhs: ChannelView) -> Bool {
        // Equatable on the version + isBeta is enough for tests; full struct
        // equality would require DownloadEntry to be Equatable too.
        lhs.version == rhs.version && lhs.isBeta == rhs.isBeta
    }
}

func pickChannel(info: LatestInfo, useBeta: Bool) -> ChannelView {
    let stable = ChannelView(
        version: info.version,
        notesZh: info.notesZh,
        notesEn: info.notesEn,
        downloads: info.downloads,
        checksums: info.checksums,
        isBeta: false
    )
    // Beta wins only when strictly newer than stable. Once beta has been
    // promoted to stable (publish-release.sh clears the field, but defend
    // against stale CDN copies too), beta-channel users automatically
    // fall back to stable and pick up the upgrade prompt.
    guard useBeta,
          let beta = info.beta,
          SemanticVersion.compare(beta.version, info.version) > 0
    else {
        return stable
    }
    return ChannelView(
        version: beta.version,
        notesZh: beta.notesZh,
        notesEn: beta.notesEn,
        downloads: beta.downloads,
        checksums: beta.checksums,
        isBeta: true
    )
}

private struct ReleaseInfo: Codable {
    let tag_name: String
    let name: String?
    let body: String?
    let html_url: String?
    let prerelease: Bool?
    let assets: [Asset]?

    struct Asset: Codable {
        let name: String
        let browser_download_url: String
        let size: Int?
    }
}

// MARK: - Download Delegate

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let onProgress: @Sendable (Double, Int64, Int64) -> Void
    let onComplete: @Sendable (URL) -> Void
    let onError: @Sendable (String) -> Void

    init(
        onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void,
        onComplete: @escaping @Sendable (URL) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.onProgress = onProgress
        self.onComplete = onComplete
        self.onError = onError
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("PasteMemo-update.dmg")
        try? FileManager.default.removeItem(at: dest)

        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            do {
                try FileManager.default.copyItem(at: location, to: dest)
            } catch {
                onComplete(location)
                return
            }
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let fileSize = attrs[.size] as? Int64,
           let response = downloadTask.response as? HTTPURLResponse,
           response.expectedContentLength > 0,
           fileSize != response.expectedContentLength {
            try? FileManager.default.removeItem(at: dest)
        }

        onComplete(dest)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 1
        let progress = Double(totalBytesWritten) / Double(total)
        onProgress(progress, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            onError(error.localizedDescription)
        }
    }
}
