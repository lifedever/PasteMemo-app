import AppKit
import CryptoKit
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
    /// Drives the BETA badge on the Software Update page.
    @Published var isBetaUpdate = false

    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var downloadComplete = false
    @Published var downloadedFileURL: URL?

    /// 最近一次出的问题，显示在「软件更新」页上。更新流程里不再弹任何 alert。
    @Published var lastIssue: UpdateIssue?
    /// 最近一次成功检查的时间（持久化在 `lastUpdateCheck`）
    @Published private(set) var lastCheckedAt: Date? =
        UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date

    /// 设置里「检查频率」的默认值。界面和定时器都用它，之前界面显示 24 小时、
    /// 定时器读不到值按 0 算、再被 max(_, 6) 抬成 6 小时，两边对不上。
    nonisolated static let defaultCheckIntervalHours = 24

    private let latestJsonURL = "https://www.lifedever.com/PasteMemo/latest.json"
    private let repoOwner = "lifedever"
    private let repoName = "PasteMemo-app"
    private let giteeRepo = "lifedever/pastememo"

    private var downloadTask: URLSessionDownloadTask?
    private var downloadDelegate: DownloadDelegate?
    private var githubFallbackURL: URL?
    private var periodicTimer: Timer?
    /// 每开始 / 取消一次下载 +1。下载回调带着开始时的编号，对不上就是过期回调
    /// （典型：点「取消」后系统随即报的 cancelled 错误，之前会被当成失败去重试备用地址）。
    private var downloadGeneration = 0
    /// 已下载好的 DMG 是哪个版本。又发了新版时靠它判断旧包作废。
    private var downloadedVersion: String?
    /// 这次下载是后台自动发起的（自动安装）。失败时要补发通知，用户主动点的不用。
    private var isBackgroundDownload = false
    /// 开了「自动安装更新」且包已下好时，每分钟看一次是否闲置。
    private var idleInstallTimer: Timer?
    /// 连续几次检查都是闲置。合盖睡一晚后定时器在开盖那一刻补触发，闲置时长可能
    /// 把整晚都算进去——要求连续两次（间隔一分钟）都闲置，用户刚回来就不会被重启赶上。
    private var consecutiveIdlePolls = 0

    static let autoInstallKey = "autoInstallUpdates"
    /// 后台发现新版本时同一版本只发一次通知
    private static let notifiedVersionKey = "notifiedUpdateVersion"
    /// 静默安装前记下版本和更新内容，重启后发「已更新到 x」
    private static let autoInstalledVersionKey = "autoInstalledVersion"
    private static let autoInstalledNotesKey = "autoInstalledNotes"
    /// 某个版本静默安装失败过（如 /Applications 没写权限）：这个版本不再自动装，
    /// 改回发通知，免得每次检查都重新下载、重启一遍
    private static let autoInstallFailedVersionKey = "autoInstallFailedVersion"
    /// Expected SHA-256 of the DMG, taken from `latest.json`'s `checksums`
    /// entry. Used to verify download integrity before install. Nil when the
    /// feed lacks a checksum (e.g. Gitee/GitHub API fallback), in which case
    /// only the byte-size check runs.
    private var expectedSHA256: String?

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
        devFeedOverride ?? latestJsonURL
    }

    private var devFeedOverride: String? {
        guard isDev,
              let override = UserDefaults.standard.string(forKey: "devLatestJsonOverride"),
              !override.isEmpty else { return nil }
        return override
    }

    /// Dev 版平时不做自动检查；指向本地 mock feed 时放开，用来验证后台通知 / 自动安装路径。
    private var allowsAutomaticChecks: Bool { !isDev || devFeedOverride != nil }

    private var autoCheckEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true
    }

    /// 「自动安装更新」只在自动检查开着时生效（关了自动检查，开关在设置里也藏起来了）。
    var autoInstallEnabled: Bool {
        autoCheckEnabled && UserDefaults.standard.bool(forKey: Self.autoInstallKey)
    }

    private init() {}

    // MARK: - Check

    /// 只更新状态，不弹任何界面。结果由「软件更新」页（和状态栏、通知）展示。
    /// - Parameter userInitiated: 用户点的「检查更新」。会忽略「跳过的版本」，失败时在页面上报错。
    func checkForUpdates(userInitiated: Bool = false) async {
        guard userInitiated || allowsAutomaticChecks else { return }
        if !userInitiated {
            guard autoCheckEnabled else { return }
        }
        // 正在下载：下载要用的 URL、校验值都别动，页面上也正显示着进度，等它下完
        guard !isDownloading, !isChecking else { return }

        isChecking = true
        defer { isChecking = false }
        if userInitiated { lastIssue = nil }

        // Primary: static JSON (no rate limit)
        var remoteVersion: String?
        var notes: String?
        var archDownloadURL: URL?
        // Reset before each check so a stale beta flag from a previous run
        // doesn't bleed into a stable-channel result.
        isBetaUpdate = false
        // Same for the expected checksum: a fallback path (Gitee/GitHub API)
        // has no sha256, so clear any value left over from a prior check to
        // avoid verifying this download against a stale hash.
        expectedSHA256 = nil

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
            expectedSHA256 = entry?.sha256

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
            if userInitiated { lastIssue = .checkFailed }
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

        let now = Date()
        UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
        lastCheckedAt = now
        // 之前手动检查失败过、这次（哪怕是后台检查）成功了：页面上那行错误该消失
        if lastIssue == .checkFailed { lastIssue = nil }

        // 已下好的包不是这个版本了（又发了新版，或版本被撤回）→ 作废，免得装错
        if downloadComplete, downloadedVersion != remoteVersion {
            discardDownload()
        }

        if updateAvailable {
            // 用户自己点的检查：结果就在他正看着的「软件更新」页上，不用再通知
            if !userInitiated {
                handleUpdateFoundInBackground(version: remoteVersion)
            }
        } else {
            disarmIdleInstall()
        }
    }

    /// 自动检查发现新版本：不弹窗、不抢前台。开了自动安装就后台下载、闲置时装；
    /// 没开就发一条系统通知（同一版本只发一次）。两种情况状态栏图标都挂小圆点。
    private func handleUpdateFoundInBackground(version: String) {
        DiagnosticLog.log("UPDATE found \(version) in background; autoInstall=\(autoInstallEnabled)")
        let failedBefore = UserDefaults.standard.string(forKey: Self.autoInstallFailedVersionKey) == version
        if autoInstallEnabled && !failedBefore {
            if downloadComplete {
                armIdleInstall()
            } else if !isDownloading {
                startDownload(background: true)
            }
            return
        }
        notifyOnce(version: version)
    }

    private func notifyOnce(version: String) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.notifiedVersionKey) != version else { return }
        defaults.set(version, forKey: Self.notifiedVersionKey)
        UpdateNotifier.shared.notifyAvailable(version: version, notes: releaseNotes)
    }

    /// 设置里切换「自动安装更新」：打开时如果已经有新版本，马上开始后台下载。
    func autoInstallSettingChanged() {
        guard autoInstallEnabled else {
            disarmIdleInstall()
            return
        }
        guard updateAvailable, !isDownloading else { return }
        if downloadComplete {
            armIdleInstall()
        } else {
            startDownload(background: true)
        }
    }

    /// 静默安装重启后发「已更新到 x」，让用户知道刚换了版本、改了什么。
    func announceAutoInstallIfNeeded() {
        let defaults = UserDefaults.standard
        guard let version = defaults.string(forKey: Self.autoInstalledVersionKey) else { return }
        let notes = defaults.string(forKey: Self.autoInstalledNotesKey)
        defaults.removeObject(forKey: Self.autoInstalledVersionKey)
        defaults.removeObject(forKey: Self.autoInstalledNotesKey)
        // 版本对不上 = 替换没成功，旧版本又起来了：不报，这个版本也不再自动装
        guard version == currentVersion else {
            DiagnosticLog.log("UPDATE auto-install marker \(version) != running \(currentVersion)")
            defaults.set(version, forKey: Self.autoInstallFailedVersionKey)
            return
        }
        UpdateNotifier.shared.notifyInstalled(version: version, notes: notes)
    }

    // MARK: - Download

    /// 「软件更新」页上点「安装更新」
    func downloadUpdate() {
        startDownload(background: false)
    }

    private func startDownload(background: Bool) {
        guard let url = downloadURL else { return }
        isBackgroundDownload = background
        lastIssue = nil
        startDownload(from: url)
    }

    func cancelDownload() {
        downloadGeneration += 1
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        downloadComplete = false
    }

    func skipVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: "skippedVersion")
        updateAvailable = false
        // 跳过的版本不能被闲置安装偷偷装上
        if downloadedVersion == version { discardDownload() }
    }

    private func discardDownload() {
        disarmIdleInstall()
        downloadComplete = false
        downloadedFileURL = nil
        downloadedVersion = nil
        downloadProgress = 0
    }

    // MARK: - Idle install

    private func armIdleInstall() {
        guard idleInstallTimer == nil else { return }
        DiagnosticLog.log("UPDATE armed idle install for \(downloadedVersion ?? "?")")
        idleInstallTimer = Timer.scheduledTimer(
            withTimeInterval: AutoInstallGate.pollInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.installIfIdle() }
        }
    }

    private func disarmIdleInstall() {
        idleInstallTimer?.invalidate()
        idleInstallTimer = nil
        consecutiveIdlePolls = 0
    }

    private func installIfIdle() {
        guard autoInstallEnabled, downloadComplete, let version = downloadedVersion else {
            disarmIdleInstall()
            return
        }
        let ready = AutoInstallGate.isReady(
            idleSeconds: AutoInstallGate.systemIdleSeconds(),
            appIsActive: NSApp.isActive,
            relayActive: RelayManager.shared.isActive,
            hasOpenWorkWindow: hasOpenWorkWindow
        )
        consecutiveIdlePolls = ready ? consecutiveIdlePolls + 1 : 0
        guard consecutiveIdlePolls >= 2 else { return }
        disarmIdleInstall()
        // Dev 版的 bundlePath 是 PasteMemo Dev.app，拿正式版 DMG 原地替换会把它整个变成正式版
        guard !isDev else {
            DiagnosticLog.log("UPDATE dev build: would auto-install \(version) now, skipped")
            return
        }
        DiagnosticLog.log("UPDATE idle auto-install \(version)")
        let defaults = UserDefaults.standard
        defaults.set(version, forKey: Self.autoInstalledVersionKey)
        defaults.set(releaseNotes, forKey: Self.autoInstalledNotesKey)
        installAndRestart(inBackground: true)
    }

    /// 开着的 PasteMemo 窗口里可能有没保存的编辑（规则编辑器、拆分、新手引导…），
    /// 有就不装。管理器和设置不算：常驻不关的人多，里面也没有要手动保存的内容。
    private var hasOpenWorkWindow: Bool {
        let ignorable: Set<String> = ["main", "settings"]
        let hasWindow = NSApp.windows.contains { window in
            window.isVisible
                && window.styleMask.contains(.titled)
                && !ignorable.contains(window.identifier?.rawValue ?? "")
        }
        return hasWindow || QuickPanelWindowController.shared.isVisible
    }

    // MARK: - Install

    /// - Parameter inBackground: 闲置时自动安装。出错时补发通知（用户不在电脑前），
    ///   重启用 `open -g`，不把 PasteMemo 拉到前台。
    func installAndRestart(inBackground: Bool = false) {
        guard let fileURL = downloadedFileURL else { return }

        // 替换脚本在 App 退出后才跑，没写权限时它静默失败、旧版本又被拉起来。
        // 后台安装没人看着，先查一遍，不行就别退出了
        if inBackground,
           !FileManager.default.isWritableFile(atPath: Bundle.main.bundlePath + "/Contents") {
            handleInstallFailure(inBackground: true)
            return
        }

        let mountResult = mountDMG(at: fileURL.path)
        guard let mountPoint = mountResult else {
            handleInstallFailure(inBackground: inBackground)
            return
        }

        let sourceApp = "\(mountPoint)/PasteMemo.app"
        guard FileManager.default.fileExists(atPath: sourceApp) else {
            detachDMG(mountPoint)
            handleInstallFailure(inBackground: inBackground)
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
        rm -rf "\(destApp)/Contents/_CodeSignature"
        rm -rf "\(destApp)"/*.bundle
        cp -R "\(sourceApp)/Contents/MacOS" "\(destApp)/Contents/MacOS"
        cp -R "\(sourceApp)/Contents/Resources" "\(destApp)/Contents/Resources"
        cp "\(sourceApp)/Contents/Info.plist" "\(destApp)/Contents/Info.plist"
        # Signed (Developer ID) builds seal the bundle via Contents/_CodeSignature;
        # leaving the old one behind after swapping MacOS/Resources produces an
        # app whose signature no longer verifies (broken seal → Gatekeeper/TCC
        # trouble). Copy it together with the content it seals.
        if [ -d "\(sourceApp)/Contents/_CodeSignature" ]; then
            cp -R "\(sourceApp)/Contents/_CodeSignature" "\(destApp)/Contents/_CodeSignature"
        fi
        for b in "\(sourceApp)"/*.bundle; do
            [ -d "$b" ] && cp -R "$b" "\(destApp)/"
        done
        hdiutil detach "\(mountPoint)" -quiet 2>/dev/null
        open \(inBackground ? "-g " : "")"\(destApp)"
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
            if inBackground {
                handleInstallFailure(inBackground: true)
            } else {
                NSWorkspace.shared.open(fileURL)
            }
        }
    }

    private func handleInstallFailure(inBackground: Bool) {
        guard inBackground else {
            // 包坏了，作废，让用户在页面上重新下
            discardDownload()
            lastIssue = .installFailed
            return
        }
        DiagnosticLog.log("UPDATE background install failed; falling back to notification")
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.autoInstalledVersionKey)
        defaults.removeObject(forKey: Self.autoInstalledNotesKey)
        let version = downloadedVersion ?? latestVersion
        if let version { defaults.set(version, forKey: Self.autoInstallFailedVersionKey) }
        discardDownload()
        if let version { notifyOnce(version: version) }
    }

    // MARK: - Periodic

    func startPeriodicChecks() {
        periodicTimer?.invalidate()
        guard allowsAutomaticChecks, autoCheckEnabled else { return }

        let hours = Self.checkIntervalHours(
            saved: UserDefaults.standard.object(forKey: "updateCheckInterval") as? Int
        )

        periodicTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(hours * 3600), repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForUpdates()
            }
        }
    }

    /// 没设过就用界面上显示的默认值；最短 6 小时。
    nonisolated static func checkIntervalHours(saved: Int?) -> Int {
        max(saved ?? defaultCheckIntervalHours, 6)
    }

    func stopPeriodicChecks() {
        periodicTimer?.invalidate()
        periodicTimer = nil
        // 关了自动检查也就不自动安装了（已下好的包留着，手动安装还能用）
        disarmIdleInstall()
    }

    // MARK: - Private

    private func startDownload(from url: URL) {
        // 同时只留一个下载（两次后台检查撞在一起时会各起一个，写的是同一个临时文件）
        downloadTask?.cancel()
        isDownloading = true
        downloadProgress = 0
        downloadedBytes = 0
        downloadComplete = false
        downloadGeneration += 1
        let generation = downloadGeneration
        let version = latestVersion

        let delegate = DownloadDelegate(
            expectedSHA256: expectedSHA256,
            onProgress: { [weak self] progress, received, total in
                Task { @MainActor in
                    guard let self, self.downloadGeneration == generation else { return }
                    self.downloadProgress = progress
                    self.downloadedBytes = received
                    self.totalBytes = total
                }
            },
            onComplete: { [weak self] fileURL in
                Task { @MainActor in
                    guard let self, self.downloadGeneration == generation else { return }
                    self.downloadComplete = true
                    self.downloadedFileURL = fileURL
                    self.downloadedVersion = version
                    self.isDownloading = false
                    DiagnosticLog.log("UPDATE downloaded \(version ?? "?")")
                    if self.autoInstallEnabled { self.armIdleInstall() }
                }
            },
            onError: { [weak self] errorInfo in
                Task { @MainActor in
                    // 过期回调：点了「取消」后系统报的 cancelled，或已被新下载取代
                    guard let self, self.downloadGeneration == generation else { return }
                    if let fallback = self.githubFallbackURL, url != fallback {
                        self.githubFallbackURL = nil
                        self.startDownload(from: fallback)
                    } else {
                        self.isDownloading = false
                        self.downloadComplete = false
                        self.downloadProgress = 0
                        DiagnosticLog.log("UPDATE download failed (background=\(self.isBackgroundDownload)): \(errorInfo)")
                        // The delegate runs off the main actor, so it passes a
                        // localization key for our own integrity errors (it
                        // can't call L10n.tr). System URLSession errors arrive
                        // as an already-localized description. Translate the
                        // former; pass the latter through unchanged.
                        let message = errorInfo == DownloadDelegate.incompleteDownloadKey
                            ? L10n.tr(errorInfo)
                            : errorInfo
                        self.lastIssue = .downloadFailed(message)
                        // 后台自动下载失败：用户没在看页面，补发通知，下次自动检查再试
                        if self.isBackgroundDownload, let version {
                            self.notifyOnce(version: version)
                        }
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
        // 加时间戳做 cache-bust：latest.json 在 CDN 上有 10 分钟缓存，
        // reloadIgnoringLocalCacheData 只越过本地缓存、越不过 CDN 边缘缓存，
        // 导致刚发布的新版本要等 CDN 过期才查得到。每次唯一 URL → CDN 必回源取最新。
        let separator = resolvedLatestJsonURL.contains("?") ? "&" : "?"
        let bustedURL = "\(resolvedLatestJsonURL)\(separator)t=\(Int(Date().timeIntervalSince1970))"
        guard let url = URL(string: bustedURL) else { return nil }
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
}

// MARK: - Models

/// 「软件更新」页上显示的问题。以前每种都弹一个 NSAlert，现在只在页面上写一行。
enum UpdateIssue: Equatable {
    /// 拿不到最新版本信息（网络、服务器）
    case checkFailed
    /// 下载失败；带系统给的原因或我们自己的完整性校验文案
    case downloadFailed(String)
    /// 下好的 DMG 挂载不了 / 里面没有 app
    case installFailed
}

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
    /// Localization key passed to `onError` when the download is truncated,
    /// interrupted, or fails integrity checks. Localized on the MainActor side
    /// (this delegate runs off the main actor and can't call `L10n.tr`).
    static let incompleteDownloadKey = "update.download_error.incomplete"

    /// Expected SHA-256 (lowercase hex) of the DMG, or nil to skip hash
    /// verification (byte-size check still runs).
    let expectedSHA256: String?
    let onProgress: @Sendable (Double, Int64, Int64) -> Void
    let onComplete: @Sendable (URL) -> Void
    let onError: @Sendable (String) -> Void

    init(
        expectedSHA256: String? = nil,
        onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void,
        onComplete: @escaping @Sendable (URL) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.expectedSHA256 = expectedSHA256
        self.onProgress = onProgress
        self.onComplete = onComplete
        self.onError = onError
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("PasteMemo-update.dmg")
        try? FileManager.default.removeItem(at: dest)

        // The URLSession-provided `location` is a temporary file the system
        // deletes as soon as this callback returns, so it must be moved to a
        // stable path before we can hand it off. If both move and copy fail we
        // have no usable file — report an error rather than passing a URL that
        // is about to vanish (which would surface later as a bogus
        // "disk image corrupted" alert at install time).
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            do {
                try FileManager.default.copyItem(at: location, to: dest)
            } catch {
                onError(Self.incompleteDownloadKey)
                return
            }
        }

        // Verify byte size against the server's declared content length. A
        // truncated download (slow/unstable CDN, interrupted connection) fails
        // here — treat it as an error so the caller can retry or fall back,
        // instead of proceeding to install a partial file.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let fileSize = attrs[.size] as? Int64,
           let response = downloadTask.response as? HTTPURLResponse,
           response.expectedContentLength > 0,
           fileSize != response.expectedContentLength {
            try? FileManager.default.removeItem(at: dest)
            onError(Self.incompleteDownloadKey)
            return
        }

        // Verify SHA-256 against the checksum from latest.json. Catches the
        // "size matches but bytes are wrong" case — e.g. a CDN caching a stale
        // or corrupt image. Skipped when the feed provided no checksum.
        if let expected = expectedSHA256?.lowercased(), !expected.isEmpty {
            guard let data = try? Data(contentsOf: dest) else {
                try? FileManager.default.removeItem(at: dest)
                onError(Self.incompleteDownloadKey)
                return
            }
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if actual != expected {
                try? FileManager.default.removeItem(at: dest)
                onError(Self.incompleteDownloadKey)
                return
            }
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
