import SwiftUI

@MainActor
enum L10n {
    static let supportedLanguages: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("en", "English"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("es", "Español"),
        ("it", "Italiano"),
        ("ru", "Русский"),
        ("id", "Bahasa Indonesia"),
    ]

    static func tr(_ key: String) -> String {
        let lang = LanguageManager.shared.current
        guard let path = Bundle.module.path(forResource: lang, ofType: "lproj")
                ?? Bundle.module.paths(forResourcesOfType: "lproj", inDirectory: nil)
                    .first(where: { $0.lowercased().contains(lang.lowercased()) }),
              let bundle = Bundle(path: path)
        else {
            return NSLocalizedString(key, bundle: .module, comment: "")
        }
        return NSLocalizedString(key, bundle: bundle, comment: "")
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), arguments: args)
    }

    /// The SPM-generated resource bundle that holds our `.lproj` directories.
    /// Exposed for tests; production code keeps using `Bundle.module` directly.
    static var resourceBundle: Bundle { .module }
}

@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()
    @AppStorage("appLanguage") var current: String = ""

    private init() {
        // Auto-detect system language on first launch
        if current.isEmpty {
            current = detectSystemLanguage()
        }
    }

    func setLanguage(_ lang: String) {
        current = lang
        objectWillChange.send()
    }

    /// Detect system language and match to supported languages
    private func detectSystemLanguage() -> String {
        let preferred = Locale.preferredLanguages
        let supportedCodes = L10n.supportedLanguages.map(\.code)

        for lang in preferred {
            // Exact match
            if supportedCodes.contains(lang) {
                return lang
            }
            // Prefix match: "zh-Hans-CN" → "zh-Hans", "ja-JP" → "ja"
            for code in supportedCodes {
                if lang.hasPrefix(code) {
                    return code
                }
            }
            // Base language match: "zh" → "zh-Hans"
            let base = lang.components(separatedBy: "-").first ?? lang
            if let match = supportedCodes.first(where: { $0.hasPrefix(base) }) {
                return match
            }
        }

        return "en"
    }
}

@MainActor
struct LocalizedViewModifier: ViewModifier {
    @ObservedObject private var languageManager = LanguageManager.shared

    func body(content: Content) -> some View {
        content
            .id(languageManager.current)
    }
}

extension View {
    @MainActor
    func localized() -> some View {
        modifier(LocalizedViewModifier())
    }
}
