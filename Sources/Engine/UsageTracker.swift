import Foundation

private extension ProcessInfo {
    var machineArchitecture: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0) ?? "unknown"
            }
        }
    }
}

enum PingSource: String {
    case launch
    case quick
    case main
}

@MainActor
enum UsageTracker {
    private static let PING_URL = "https://stats.pastememo.lifedever.com/ping"
    private static let LAST_PING_KEY = "usageTracker.lastPingDate"
    private static let DEVICE_ID_KEY = "usageTracker.deviceId"
    static let ANALYTICS_ENABLED_KEY = "analyticsEnabled"
    static let ANALYTICS_ASKED_KEY = "analyticsAsked"

    // One ping in flight at a time. Set right before firing, cleared in the
    // completion handler. Stops the launch / quick / main triggers from each
    // firing their own ping on the same day in the window before the first
    // response lands and commits LAST_PING_KEY.
    private static var pingInFlight = false

    // Dedup uses the SAME day boundary the dashboard buckets by — Asia/Shanghai,
    // matching the dashboard's `timestamp + INTERVAL '8' HOUR`. The local calendar
    // would drift "once per day" away from how daily-active is counted server-side
    // for users outside +08:00.
    private static let pingCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        if let tz = TimeZone(identifier: "Asia/Shanghai") { cal.timeZone = tz }
        return cal
    }()

    static var isEnabled: Bool {
        get {
            // Offline mode is the master kill switch — when on, no anonymous
            // ping leaves the machine regardless of the analytics preference.
            if UserDefaults.standard.bool(forKey: "offlineModeEnabled") { return false }
            return UserDefaults.standard.object(forKey: ANALYTICS_ENABLED_KEY) as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: ANALYTICS_ENABLED_KEY) }
    }

    static var hasAskedConsent: Bool {
        // `analyticsAsked` is set when the onboarding consent screen is dismissed.
        // Already-onboarded users (from versions before this flag was wired up)
        // are treated as having consented, so the installed base doesn't go dark.
        UserDefaults.standard.bool(forKey: ANALYTICS_ASKED_KEY)
            || UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }

    static func markConsentAsked() {
        UserDefaults.standard.set(true, forKey: ANALYTICS_ASKED_KEY)
    }

    private static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: DEVICE_ID_KEY) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: DEVICE_ID_KEY)
        return newId
    }

    static func pingIfNeeded(source: PingSource = .launch) {
        guard isEnabled else { return }
        // Hold the first ping until the user has seen the analytics-consent screen
        // in onboarding. Analytics defaults on (opt-out), so without this a brand-new
        // install would ping before the user ever has a chance to decline.
        guard hasAskedConsent else { return }
        guard !pingInFlight else { return }

        let today = pingCalendar.startOfDay(for: Date())
        let lastPing = UserDefaults.standard.object(forKey: LAST_PING_KEY) as? Date ?? .distantPast
        guard pingCalendar.startOfDay(for: lastPing) < today else { return }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let lang = Locale.current.language.languageCode?.identifier ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let arch = ProcessInfo.processInfo.machineArchitecture

        var components = URLComponents(string: PING_URL)
        components?.queryItems = [
            URLQueryItem(name: "v", value: version),
            URLQueryItem(name: "lang", value: lang),
            URLQueryItem(name: "os", value: os),
            URLQueryItem(name: "arch", value: arch),
            URLQueryItem(name: "did", value: deviceId),
            URLQueryItem(name: "src", value: source.rawValue),
        ]
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        pingInFlight = true
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let success = (response as? HTTPURLResponse)?.statusCode == 200
            Task { @MainActor in
                // On success LAST_PING_KEY now blocks further pings today; on
                // failure clearing the flag lets a later trigger retry today.
                if success { UserDefaults.standard.set(today, forKey: LAST_PING_KEY) }
                pingInFlight = false
            }
        }.resume()
    }
}
