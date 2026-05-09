import Foundation

/// SemVer 2.0.0 §11 precedence comparison.
///
/// The previous implementation used `compactMap { Int($0) }` which silently
/// dropped non-numeric segments — `"1.7.0-beta.1"` became `[1, 7, 1]`, ranking
/// it ABOVE `"1.7.0"` and breaking the beta→stable upgrade path.
enum SemanticVersion {
    /// Returns true iff `remote` is strictly newer than `current`.
    static func isNewer(remote: String, current: String) -> Bool {
        compare(remote, current) > 0
    }

    /// Positive if `a > b`, negative if `a < b`, zero if equal.
    static func compare(_ a: String, _ b: String) -> Int {
        let (aCore, aPre) = split(a)
        let (bCore, bPre) = split(b)

        let aParts = aCore.split(separator: ".").map { Int($0) ?? 0 }
        let bParts = bCore.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(aParts.count, bParts.count) {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av < bv ? -1 : 1 }
        }

        // Core equal: a release version has higher precedence than a pre-release.
        if aPre.isEmpty && bPre.isEmpty { return 0 }
        if aPre.isEmpty { return 1 }
        if bPre.isEmpty { return -1 }

        let aIds = aPre.split(separator: ".").map(String.init)
        let bIds = bPre.split(separator: ".").map(String.init)
        for i in 0..<min(aIds.count, bIds.count) {
            let result = compareIdentifier(aIds[i], bIds[i])
            if result != 0 { return result }
        }
        if aIds.count == bIds.count { return 0 }
        return aIds.count < bIds.count ? -1 : 1
    }

    private static func split(_ s: String) -> (core: String, pre: String) {
        guard let idx = s.firstIndex(of: "-") else { return (s, "") }
        return (String(s[..<idx]), String(s[s.index(after: idx)...]))
    }

    /// Per SemVer §11.4: numeric identifiers compare numerically; alphanumerics
    /// compare lexically; numeric < alphanumeric when types differ.
    private static func compareIdentifier(_ a: String, _ b: String) -> Int {
        let aNum = Int(a)
        let bNum = Int(b)
        switch (aNum, bNum) {
        case let (av?, bv?):
            if av == bv { return 0 }
            return av < bv ? -1 : 1
        case (nil, nil):
            if a == b { return 0 }
            return a < b ? -1 : 1
        case (_?, nil):
            return -1
        case (nil, _?):
            return 1
        }
    }
}
