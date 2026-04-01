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

    private static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: DEVICE_ID_KEY) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: DEVICE_ID_KEY)
        return newId
    }

    static func pingIfNeeded(source: PingSource = .launch) {
        let today = Calendar.current.startOfDay(for: Date())
        let lastPing = UserDefaults.standard.object(forKey: LAST_PING_KEY) as? Date ?? .distantPast
        guard Calendar.current.startOfDay(for: lastPing) < today else { return }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let lang = Locale.current.language.languageCode?.identifier ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let arch = ProcessInfo.processInfo.machineArchitecture
        let pro = ProManager.shared.isPro ? "1" : "0"

        var components = URLComponents(string: PING_URL)
        components?.queryItems = [
            URLQueryItem(name: "v", value: version),
            URLQueryItem(name: "lang", value: lang),
            URLQueryItem(name: "os", value: os),
            URLQueryItem(name: "arch", value: arch),
            URLQueryItem(name: "did", value: deviceId),
            URLQueryItem(name: "pro", value: pro),
            URLQueryItem(name: "src", value: source.rawValue),
        ]
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                DispatchQueue.main.async {
                    UserDefaults.standard.set(today, forKey: LAST_PING_KEY)
                }
            }
        }.resume()
    }
}
