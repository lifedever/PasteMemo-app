import Foundation
import SwiftData

@Observable
@MainActor
final class SyncScheduler {
    static let shared = SyncScheduler()

    var isSyncing = false
    var syncProgressCurrent = 0
    var syncProgressTotal = 0
    private(set) var lastSyncError: String?

    private(set) var modelContainer: ModelContainer?
    private var timer: Timer?

    private init() {
        lastSyncError = UserDefaults.standard.string(forKey: SyncSettings.lastErrorKey)
    }

    var lastCompletedAt: Date? {
        SyncSettings.lastCompletedAt
    }

    var lastSyncCount: Int {
        UserDefaults.standard.integer(forKey: SyncSettings.lastSyncCountKey)
    }

    var lastSyncDownloaded: Int {
        UserDefaults.standard.integer(forKey: SyncSettings.lastSyncDownloadedKey)
    }

    var lastSyncDeleted: Int {
        UserDefaults.standard.integer(forKey: SyncSettings.lastSyncDeletedKey)
    }

    var nextSyncDate: Date? {
        guard SyncSettings.isEnabled, !SyncSettings.isAutoPaused, let last = lastCompletedAt else {
            return nil
        }
        return last.addingTimeInterval(SyncSettings.interval)
    }

    func start(container: ModelContainer) {
        modelContainer = container
        reschedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func resumeAutoSync() {
        UserDefaults.standard.set(false, forKey: SyncSettings.autoPausedKey)
        reschedule()
    }

    func syncNow() async {
        guard let container = modelContainer else { return }
        guard !isSyncing else { return }

        isSyncing = true
        syncProgressCurrent = 0
        syncProgressTotal = 0
        clearLastError()
        defer {
            isSyncing = false
            syncProgressCurrent = 0
            syncProgressTotal = 0
        }

        do {
            let result = try await SyncEngine.performSync(container: container) { [weak self] current, total in
                self?.syncProgressCurrent = current
                self?.syncProgressTotal = total
            }
            let defaults = UserDefaults.standard
            defaults.set(Date(), forKey: SyncSettings.lastCompletedAtKey)
            defaults.set(result.uploaded, forKey: SyncSettings.lastSyncCountKey)
            defaults.set(result.downloaded, forKey: SyncSettings.lastSyncDownloadedKey)
            defaults.set(result.deleted, forKey: SyncSettings.lastSyncDeletedKey)
            clearLastError()
            defaults.set(false, forKey: SyncSettings.autoPausedKey)
            reschedule()
        } catch SyncError.noItems {
            let defaults = UserDefaults.standard
            defaults.set(Date(), forKey: SyncSettings.lastCompletedAtKey)
            defaults.set(0, forKey: SyncSettings.lastSyncCountKey)
            defaults.set(0, forKey: SyncSettings.lastSyncDownloadedKey)
            defaults.set(0, forKey: SyncSettings.lastSyncDeletedKey)
            clearLastError()
            defaults.set(false, forKey: SyncSettings.autoPausedKey)
            reschedule()
        } catch {
            let message: String
            if let syncError = error as? SyncError {
                message = syncError.localizedDescription()
            } else {
                message = error.localizedDescription
            }
            setLastError(message)
            UserDefaults.standard.set(true, forKey: SyncSettings.autoPausedKey)
            stop()
        }
    }

    private func clearLastError() {
        lastSyncError = nil
        UserDefaults.standard.removeObject(forKey: SyncSettings.lastErrorKey)
    }

    private func setLastError(_ message: String) {
        lastSyncError = message
        UserDefaults.standard.set(message, forKey: SyncSettings.lastErrorKey)
    }

    func reschedule() {
        stop()
        guard SyncSettings.isEnabled, !SyncSettings.isAutoPaused else { return }

        if let lastDate = lastCompletedAt {
            let elapsed = Date().timeIntervalSince(lastDate)
            let remaining = SyncSettings.interval - elapsed
            if remaining <= 0 {
                Task { await syncNow() }
            } else {
                scheduleTimer(after: remaining)
            }
        } else if SyncSettings.isEnabled {
            Task { await syncNow() }
        }
    }

    private func scheduleTimer(after interval: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.syncNow()
            }
        }
    }
}
