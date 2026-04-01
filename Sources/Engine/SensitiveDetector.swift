import Foundation
import AppKit

enum SensitiveDetector {

    // MARK: - Public API

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "sensitiveDetectionEnabled") as? Bool ?? true
    }

    static func isSensitive(content: String, sourceAppBundleID: String?, contentType: ClipContentType = .text) -> Bool {
        guard isEnabled else { return false }
        // Skip detection for non-text types (image, file, video, audio)
        guard !contentType.isFileBased else { return false }
        // Password manager: mark as sensitive unless it's identifiable info (email, phone, name, URL)
        if isPasswordManagerApp(sourceAppBundleID), !isIdentifiableInfo(content) { return true }
        if containsKeywordWithContext(content) { return true }
        if matchesSensitivePattern(content) { return true }
        if isHighEntropyString(content) { return true }
        return false
    }

    // MARK: - Source App Detection

    static let PASSWORD_MANAGER_APPS: [(bundleID: String, name: String)] = [
        ("com.apple.Passwords", "Passwords"),
        ("com.apple.keychainaccess", "Keychain Access"),
        ("com.1password.1password", "1Password"),
        ("com.agilebits.onepassword7", "1Password 7"),
        ("com.bitwarden.desktop", "Bitwarden"),
        ("org.keepassxc.keepassxc", "KeePassXC"),
        ("com.lastpass.LastPass", "LastPass"),
        ("com.enpass.Enpass", "Enpass"),
        ("in.sinew.Enpass-Desktop", "Enpass"),
    ]

    private static let PASSWORD_MANAGER_BUNDLE_IDS: Set<String> = Set(PASSWORD_MANAGER_APPS.map(\.bundleID))

    static func isPasswordManager(_ bundleID: String) -> Bool {
        PASSWORD_MANAGER_BUNDLE_IDS.contains(bundleID)
    }

    /// Returns password manager apps that are installed on this system.
    /// Uses the system-localized app name when available (e.g. "密码" for Passwords.app in Chinese).
    static func installedPasswordManagers() -> [(bundleID: String, name: String, icon: NSImage)] {
        PASSWORD_MANAGER_APPS.compactMap { app in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let localizedName = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            let name = localizedName.isEmpty ? app.name : localizedName
            return (bundleID: app.bundleID, name: name, icon: icon)
        }
    }

    private static func isPasswordManagerApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return isPasswordManager(bundleID)
    }

    // MARK: - Identifiable Info (not sensitive even from password managers)

    /// Content that looks like user-identifiable info: email, phone, URL, pure Chinese text, plain name, etc.
    private static func isIdentifiableInfo(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if isEmail(trimmed) { return true }
        if isPhoneNumber(trimmed) { return true }
        if isURL(trimmed) { return true }
        if isPureCJKText(trimmed) { return true }
        if isPlainName(trimmed) { return true }
        if isNumericOnly(trimmed) { return true }
        return false
    }

    private static func isEmail(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }

    private static func isPhoneNumber(_ text: String) -> Bool {
        let digits = text.filter(\.isNumber)
        guard (7...15).contains(digits.count) else { return false }
        return text.range(of: #"^[\+]?[\d\s\-\(\)\.]{7,20}$"#, options: .regularExpression) != nil
    }

    private static func isURL(_ text: String) -> Bool {
        guard !text.contains("\n") else { return false }
        return text.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil
    }

    /// Pure CJK text (Chinese/Japanese/Korean characters, no mixed random ASCII)
    private static func isPureCJKText(_ text: String) -> Bool {
        let cjkCount = text.unicodeScalars.filter { isCJKScalar($0) || $0.properties.isWhitespace }.count
        return cjkCount > text.unicodeScalars.count / 2 && text.count >= 2
    }

    private static func isCJKScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)      // CJK Unified
            || (0x3400...0x4DBF).contains(scalar.value) // CJK Extension A
            || (0x3000...0x303F).contains(scalar.value) // CJK Symbols
            || (0x3040...0x309F).contains(scalar.value) // Hiragana
            || (0x30A0...0x30FF).contains(scalar.value) // Katakana
            || (0xAC00...0xD7AF).contains(scalar.value) // Hangul
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { isCJKScalar($0) }
    }

    /// Simple name-like strings: 1-4 words, all letters, no mixed case randomness
    private static func isPlainName(_ text: String) -> Bool {
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard (1...4).contains(words.count) else { return false }
        return words.allSatisfy { word in
            word.allSatisfy { $0.isLetter || $0 == "-" || $0 == "'" }
        }
    }

    private static func isNumericOnly(_ text: String) -> Bool {
        text.allSatisfy { $0.isNumber || $0 == "." || $0 == "," || $0 == " " || $0 == "-" }
    }

    // MARK: - Keyword + Context Detection

    private static let SENSITIVE_KEYWORDS = [
        "password", "passwd", "secret", "token", "api_key",
        "private_key", "credential", "access_key", "client_secret", "auth_token",
    ]

    private static func containsKeywordWithContext(_ content: String) -> Bool {
        // Skip multi-line content (code snippets, configs) — too many false positives
        let lineCount = content.components(separatedBy: .newlines).count
        if lineCount > 3 { return false }

        let lowered = content.lowercased()
        for keyword in SENSITIVE_KEYWORDS {
            guard lowered.contains(keyword) else { continue }
            let pattern = "\(keyword)\\s*[=:\"']"
            if content.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Pattern Matching

    private static let SENSITIVE_PATTERNS: [String] = [
        "AKIA[0-9A-Z]{16}",                                                    // AWS Key
        "gh[pousr]_[A-Za-z0-9_]{36,}",                                         // GitHub Token
        "-----BEGIN.*PRIVATE KEY-----",                                          // SSH Private Key
        "eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+",            // JWT
        "Bearer\\s+[A-Za-z0-9_\\-\\.]{20,}",                                   // Bearer Token
        "xox[bpras]-[0-9a-zA-Z-]+",                                            // Slack Token
        "(secret|token|key)\\s*[:=]\\s*['\"]?[A-Za-z0-9_\\-/\\+]{20,}",       // Generic secret
    ]

    private static func matchesSensitivePattern(_ content: String) -> Bool {
        for pattern in SENSITIVE_PATTERNS {
            if content.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Randomness Scoring

    private static let RANDOMNESS_THRESHOLD = 70.0

    /// Calculates how "random" a string looks on a 0-100 scale.
    /// Combines three signals:
    /// - Shannon entropy: measures character frequency uniformity (max ~4 bits for mixed ASCII)
    /// - Transition frequency: how often the character class switches between adjacent chars
    /// - Class diversity: how many of the 4 character classes (upper/lower/digit/special) are present
    static func randomnessScore(_ text: String) -> Double {
        guard text.count >= 2 else { return 0 }

        var freq: [Character: Int] = [:]
        var transitions = 0
        var prevClass = -1
        var hasUpper = false, hasLower = false, hasDigit = false, hasSpecial = false

        for char in text {
            freq[char, default: 0] += 1
            let cls: Int
            if char.isUppercase { cls = 0; hasUpper = true }
            else if char.isLowercase { cls = 1; hasLower = true }
            else if char.isNumber { cls = 2; hasDigit = true }
            else { cls = 3; hasSpecial = true }
            if prevClass >= 0, cls != prevClass { transitions += 1 }
            prevClass = cls
        }

        // Shannon entropy (bits per character, practical max ~4.0)
        let len = Double(text.count)
        let entropy = -freq.values.reduce(0.0) { sum, count in
            let p = Double(count) / len
            return sum + p * log2(p)
        }
        let entropyScore = min(entropy / 4.0, 1.0) * 40

        // Character class transition frequency (0.0 = no switches, 1.0 = every char switches)
        let transitionScore = Double(transitions) / Double(text.count - 1) * 35

        // Character class diversity (1-4 classes present)
        let classCount = [hasUpper, hasLower, hasDigit, hasSpecial].filter { $0 }.count
        let classScore = Double(classCount) / 4.0 * 25

        return entropyScore + transitionScore + classScore
    }

    /// Pre-filters obvious non-passwords, then uses randomness scoring for the rest.
    private static func isHighEntropyString(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\n") else { return false }
        guard (8...128).contains(trimmed.count) else { return false }
        guard !trimmed.contains(" ") else { return false }
        guard !isURL(trimmed), !isEmail(trimmed), !isPhoneNumber(trimmed) else { return false }
        guard !containsCJK(trimmed) else { return false }
        guard !isCommonContent(trimmed) else { return false }

        return randomnessScore(trimmed) >= RANDOMNESS_THRESHOLD
    }

    /// Filters out common non-sensitive content patterns before entropy check
    private static func isCommonContent(_ text: String) -> Bool {
        // URL-like: protocols, paths, domains
        if text.range(of: #"https?://"#, options: .regularExpression) != nil { return true }
        if text.hasPrefix("magnet:") { return true }
        if text.hasPrefix("/") { return true }
        // Contains brackets, quotes, parens — likely code, config, or template
        if text.contains("(") || text.contains("[") || text.contains("{") { return true }
        if text.contains("\"") || text.contains("'") { return true }
        // Domain-like: word.word.word
        if text.range(of: #"^[\w.-]+\.\w{2,}$"#, options: .regularExpression) != nil { return true }
        // Hyphenated words: my-server-name-01
        if isHyphenatedWords(text) { return true }
        // Underscore-separated identifiers: vm_templates, my_variable
        if isUnderscoreIdentifier(text) { return true }
        return false
    }

    /// Strings like "my-server-name-01" — words separated by hyphens
    private static func isHyphenatedWords(_ text: String) -> Bool {
        guard text.contains("-") else { return false }
        let segments = text.split(separator: "-")
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { $0.allSatisfy { $0.isLetter || $0.isNumber } }
    }

    /// Strings like "vm_templates" or "my_var_123" — underscore-separated identifiers
    private static func isUnderscoreIdentifier(_ text: String) -> Bool {
        guard text.contains("_") else { return false }
        let segments = text.split(separator: "_")
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { $0.allSatisfy { $0.isLetter || $0.isNumber } }
    }
}
