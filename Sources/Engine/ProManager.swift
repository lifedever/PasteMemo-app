import SwiftUI

@MainActor
final class ProManager: ObservableObject {
    static let shared = ProManager()

    @AppStorage("proLicenseKey") private var storedKey: String = ""
    @Published private(set) var isPro: Bool = false

    static let FREE_FAVORITE_LIMIT = 5
    static let FREE_HISTORY_DAYS = 90

    /// Feature flag: set to true when automation is ready for release
    static let AUTOMATION_ENABLED = true

    /// Pro content types that free users cannot filter/use
    static let PRO_CONTENT_TYPES: Set<ClipContentType> = [.code, .link, .color]

    static let RETENTION_KEY = "retentionDays"

    private static let CACHED_PRO_CONFIG_KEY = "cachedProConfigEncrypted"

    func canUseContentType(_ type: ClipContentType) -> Bool {
        isPro || !Self.PRO_CONTENT_TYPES.contains(type)
    }

    var canUseAppFilter: Bool { isPro }
    var canUseAutomation: Bool { isPro }

    /// Single source of truth for retention cutoff. Returns nil when retention is "forever".
    var retentionCutoffDate: Date? {
        let userDays = UserDefaults.standard.integer(forKey: Self.RETENTION_KEY)
        let effectiveDays = isPro ? userDays : min(max(userDays, 1), Self.FREE_HISTORY_DAYS)
        guard effectiveDays > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: -effectiveDays, to: Date())
    }

    private init() {
        loadCachedConfig()
        refreshProStatus()
    }

    // MARK: - License

    func activate(key: String) -> Bool {
        guard validateKey(key) else { return false }
        storedKey = key
        refreshProStatus()
        return true
    }

    func deactivate() {
        storedKey = ""
        refreshProStatus()
    }

    // MARK: - Remote Config

    func applyRemoteConfig(encryptedBase64: String) {
        guard ProCrypto.decryptConfig(encryptedBase64) != nil else { return }
        UserDefaults.standard.set(encryptedBase64, forKey: Self.CACHED_PRO_CONFIG_KEY)
        refreshProStatus()
    }

    // MARK: - Pro Status

    private func refreshProStatus() {
        let wasPro = isPro
        isPro = resolveProStatus()

        if isPro, !wasPro {
            upgradeRetention()
        } else if !isPro, wasPro {
            downgradeRetention()
        }
    }

    private func resolveProStatus() -> Bool {
        if validateKey(storedKey) { return true }
        return isTrialActive()
    }

    private func isTrialActive() -> Bool {
        guard let cached = UserDefaults.standard.string(forKey: Self.CACHED_PRO_CONFIG_KEY),
              let config = ProCrypto.decryptConfig(cached) else { return false }
        guard let dateString = config.forceProAfter else { return true }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        guard let forceDate = formatter.date(from: dateString) else { return false }
        return Date() < forceDate
    }

    // MARK: - Retention Sync

    private func upgradeRetention() {
        // No-op: keep user's current setting, they can change it themselves
    }

    private func downgradeRetention() {
        let current = UserDefaults.standard.integer(forKey: Self.RETENTION_KEY)
        if current == 0 || current > Self.FREE_HISTORY_DAYS {
            UserDefaults.standard.set(Self.FREE_HISTORY_DAYS, forKey: Self.RETENTION_KEY)
        }
    }

    private func loadCachedConfig() {
        // Just validate cache exists — actual resolution in refreshProStatus
    }

    // MARK: - License Validation

    private func validateKey(_ key: String) -> Bool {
        // TODO: Implement license key validation
        !key.isEmpty
    }
}
