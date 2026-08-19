import Foundation
import SwiftData

@Observable
@MainActor
final class BackupScheduler {

    static let shared = BackupScheduler()

    var isBackingUp = false
    var backupProgressCurrent: Int = 0
    var backupProgressTotal: Int = 0
    var backupIsFinalizing: Bool = false
    var lastBackupDate: Date? {
        UserDefaults.standard.object(forKey: "backupLastDate") as? Date
    }
    var lastBackupError: String?

    private(set) var modelContainer: ModelContainer?
    private var timer: Timer?

    private init() {}

    func start(container: ModelContainer) {
        modelContainer = container
        reschedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func backupNow() async {
        guard let container = modelContainer else { return }
        guard !isBackingUp else { return }

        isBackingUp = true
        lastBackupError = nil
        backupProgressCurrent = 0
        backupProgressTotal = 0
        backupIsFinalizing = false
        defer {
            isBackingUp = false
            backupProgressCurrent = 0
            backupProgressTotal = 0
            backupIsFinalizing = false
        }

        do {
            await resolveWebDAVURLIfNeeded()
            let destination = buildDestination()
            try await BackupEngine.performBackup(
                container: container,
                destination: destination
            ) { [weak self] current, total, isFinalizing in
                self?.backupProgressCurrent = current
                self?.backupProgressTotal = total
                self?.backupIsFinalizing = isFinalizing
            }
            reschedule()
        } catch {
            lastBackupError = error.localizedDescription
        }
    }

    func reschedule() {
        stop()
        guard isEnabled else { return }

        if let lastDate = lastBackupDate {
            let elapsed = Date().timeIntervalSince(lastDate)
            let remaining = frequency.interval - elapsed
            if remaining <= 0 {
                Task { await backupNow() }
            } else {
                scheduleTimer(after: remaining)
            }
        } else {
            Task { await backupNow() }
        }
    }

    // MARK: - Settings Accessors

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "backupEnabled")
    }

    var nextBackupDate: Date? {
        guard isEnabled, let last = lastBackupDate else { return nil }
        return last.addingTimeInterval(frequency.interval)
    }

    var frequency: BackupFrequency {
        let raw = UserDefaults.standard.string(forKey: "backupFrequency") ?? "1d"
        return BackupFrequency(rawValue: raw) ?? .daily
    }

    var destinationType: BackupDestinationType {
        let raw = UserDefaults.standard.string(forKey: "backupDestinationType") ?? "local"
        return BackupDestinationType(rawValue: raw) ?? .local
    }

    func buildDestination() -> BackupDestination {
        switch destinationType {
        case .local:
            return LocalBackupDestination()
        case .webdav:
            let url = UserDefaults.standard.string(forKey: "webdavURL") ?? ""
            let username = UserDefaults.standard.string(forKey: "webdavUsername") ?? ""
            let password = UserDefaults.standard.string(forKey: "webdavPassword") ?? ""
            return WebDAVBackupDestination(
                serverURL: url,
                username: username,
                password: password,
                remotePath: ""
            )
        }
    }

    // MARK: - Private

    /// Users who enable WebDAV backup without ever hitting "Test Connection"
    /// may have a scheme-less server address stored. Resolve it once here
    /// and persist the result so backups (and the settings UI) use the
    /// confirmed scheme instead of guessing.
    private func resolveWebDAVURLIfNeeded() async {
        guard destinationType == .webdav else { return }
        let defaults = UserDefaults.standard
        let stored = (defaults.string(forKey: "webdavURL") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty, !stored.contains("://") else { return }
        let resolution = await WebDAVBackupDestination.resolveServerURL(
            stored,
            username: defaults.string(forKey: "webdavUsername") ?? "",
            password: defaults.string(forKey: "webdavPassword") ?? ""
        )
        if case .resolved(let url, _, _) = resolution {
            defaults.set(url, forKey: "webdavURL")
        }
        // Unresolvable: keep the stored value; buildURL falls back to HTTPS
        // and the upload error surfaces through lastBackupError as usual.
    }

    private func scheduleTimer(after interval: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.backupNow()
            }
        }
    }
}
