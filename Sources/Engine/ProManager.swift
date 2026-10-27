import SwiftUI

@MainActor
final class ProManager: ObservableObject {
    static let shared = ProManager()

    @Published private(set) var isPro: Bool = true

    /// Feature flag: set to true when automation is ready for release
    static let AUTOMATION_ENABLED = true

    static let RETENTION_KEY = "retentionDays"
    /// What the settings / onboarding pickers show for a never-written key.
    static let DEFAULT_RETENTION_DAYS = 90

    /// The pickers show 90 days for a never-written `retentionDays`, but `integer(forKey:)` reads
    /// it as 0 = forever — so every install that never touched the picker kept everything while
    /// the UI said 90 days. Pins the key once, before monitoring can run a cleanup: existing
    /// installs get 0, the forever they've been living with (switching them to 90 would silently
    /// delete months of history on the next copy, and the UI now says so honestly); fresh
    /// installs get the 90 the pickers already show.
    static func pinRetentionDefaultIfNeeded(isExistingInstall: Bool, defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: RETENTION_KEY) == nil else { return }
        defaults.set(isExistingInstall ? 0 : DEFAULT_RETENTION_DAYS, forKey: RETENTION_KEY)
    }

    func canUseContentType(_ type: ClipContentType) -> Bool { true }

    var canUseAppFilter: Bool { true }
    var canUseAutomation: Bool { true }

    /// Single source of truth for retention cutoff. Returns nil when retention is "forever".
    var retentionCutoffDate: Date? {
        let userDays = UserDefaults.standard.integer(forKey: Self.RETENTION_KEY)
        guard userDays > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: -userDays, to: Date())
    }

    private init() {}

    func applyRemoteConfig(encryptedBase64: String) {}
}
