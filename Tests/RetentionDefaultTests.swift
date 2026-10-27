import Foundation
import Testing
@testable import PasteMemo

@Suite("pinRetentionDefaultIfNeeded")
@MainActor
struct RetentionDefaultTests {
    private func freshDefaults() -> UserDefaults {
        let name = "RetentionDefaultTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Existing install that never touched the picker keeps forever")
    func existingInstall() {
        let defaults = freshDefaults()
        ProManager.pinRetentionDefaultIfNeeded(isExistingInstall: true, defaults: defaults)
        #expect(defaults.object(forKey: ProManager.RETENTION_KEY) as? Int == 0)
    }

    @Test("Fresh install gets the 90 days the pickers show")
    func freshInstall() {
        let defaults = freshDefaults()
        ProManager.pinRetentionDefaultIfNeeded(isExistingInstall: false, defaults: defaults)
        #expect(defaults.integer(forKey: ProManager.RETENTION_KEY) == ProManager.DEFAULT_RETENTION_DAYS)
    }

    @Test("A value the user picked is never overwritten", arguments: [0, 7, 365])
    func userChoice(days: Int) {
        let defaults = freshDefaults()
        defaults.set(days, forKey: ProManager.RETENTION_KEY)
        ProManager.pinRetentionDefaultIfNeeded(isExistingInstall: false, defaults: defaults)
        ProManager.pinRetentionDefaultIfNeeded(isExistingInstall: true, defaults: defaults)
        #expect(defaults.integer(forKey: ProManager.RETENTION_KEY) == days)
    }
}
