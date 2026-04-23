import AppKit

@MainActor
enum DevDataImporter {

    static let RELEASE_BUNDLE_ID = "com.lifedever.pastememo"

    static var isDevBuild: Bool {
        if ProcessInfo.processInfo.environment["PASTEMEMO_DEV"] == "1" {
            return true
        }
        return Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
    }

    static func importFromRelease() {
        guard isDevBuild else { return }

        if isReleaseAppRunning() {
            showAlert(L10n.tr("devTools.importFromRelease.releaseRunning"))
            return
        }

        guard releaseStoreExists() else {
            showAlert(L10n.tr("devTools.importFromRelease.noData"))
            return
        }

        guard showConfirmation() else { return }

        ClipboardManager.shared.stopMonitoring()
        try? PasteMemoApp.sharedModelContainer.mainContext.save()

        do {
            try copyReleaseDatabase()
            resetSeedFlags()
            relaunchApp()
        } catch {
            showAlert(error.localizedDescription)
        }
    }

    // MARK: - Checks

    private static func isReleaseAppRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: RELEASE_BUNDLE_ID).isEmpty == false
    }

    private static func releaseStoreExists() -> Bool {
        FileManager.default.fileExists(atPath: releaseStoreDir().appendingPathComponent("PasteMemo.store").path)
    }

    // MARK: - Paths

    private static func releaseStoreDir() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(RELEASE_BUNDLE_ID)
    }

    private static func devStoreDir() -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lifedever.pastememo.dev"
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(bundleID)
    }

    // MARK: - File Operations

    private static func copyReleaseDatabase() throws {
        let fm = FileManager.default
        let sourceDir = releaseStoreDir()
        let destDir = devStoreDir()

        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Remove all existing store files in dev directory first
        // This prevents stale WAL/SHM files from corrupting the imported database
        let existingFiles = try fm.contentsOfDirectory(at: destDir, includingPropertiesForKeys: nil)
        for file in existingFiles where file.lastPathComponent.hasPrefix("PasteMemo.store") {
            try fm.removeItem(at: file)
        }

        // Copy all store files from release directory
        let contents = try fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)
        let storeFiles = contents.filter { $0.lastPathComponent.hasPrefix("PasteMemo.store") }

        for sourceFile in storeFiles {
            let destFile = destDir.appendingPathComponent(sourceFile.lastPathComponent)
            try fm.copyItem(at: sourceFile, to: destFile)
        }
    }

    // MARK: - Post-Import Cleanup

    private static func resetSeedFlags() {
        // Reset built-in rules seed flag so they get re-created on next launch
        UserDefaults.standard.removeObject(forKey: "builtInRulesSeeded_v2")
    }

    // MARK: - Relaunch

    private static func relaunchApp() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1 && open \"\(path)\""]
        task.launch()
        NSApp.terminate(nil)
    }

    // MARK: - UI

    private static func showConfirmation() -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.tr("devTools.importFromRelease.confirm")
        alert.informativeText = L10n.tr("devTools.importFromRelease.confirmMessage")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("action.confirm"))
        alert.addButton(withTitle: L10n.tr("action.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}
