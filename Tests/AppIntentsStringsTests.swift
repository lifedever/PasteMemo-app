import Foundation
import Testing

/// Shortcuts reads action titles and App Shortcut phrases from the app bundle's
/// `AppIntents.strings` / `AppShortcuts.strings`, in its own process — a missing
/// key shows the raw key in Shortcuts, and nothing in the build would notice.
@Suite("Shortcuts strings")
struct AppIntentsStringsTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let localizationDir = repoRoot.appendingPathComponent("Sources/Localization")
    private static let intentsSource = repoRoot.appendingPathComponent("Sources/Bridge/ShortcutsIntents.swift")

    private static func lprojDirs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: localizationDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
    }

    private static func table(_ name: String, in lproj: URL) throws -> [String: String] {
        try #require(
            NSDictionary(contentsOf: lproj.appendingPathComponent("\(name).strings")) as? [String: String],
            "\(lproj.lastPathComponent)/\(name).strings 缺失或解析失败"
        )
    }

    /// Every `"…", table: "AppIntents"` key the intents source uses.
    private static func keysUsedInCode() throws -> Set<String> {
        let source = try String(contentsOf: intentsSource, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #""([a-zA-Z.]+)", table: "AppIntents""#)
        let ns = source as NSString
        return Set(regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) })
    }

    /// Every App Shortcut phrase in the source, `\(.applicationName)` → `${applicationName}`.
    private static func phrasesUsedInCode() throws -> Set<String> {
        let source = try String(contentsOf: intentsSource, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #""([^"]*\\\(\.applicationName\)[^"]*)""#)
        let ns = source as NSString
        return Set(regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).replacingOccurrences(of: #"\(.applicationName)"#, with: "${applicationName}")
        })
    }

    @Test("every AppIntents key used in code exists in every language")
    func intentKeys() throws {
        let used = try Self.keysUsedInCode()
        #expect(used.count >= 15)
        for lproj in try Self.lprojDirs() {
            let missing = used.subtracting(try Self.table("AppIntents", in: lproj).keys).sorted()
            #expect(missing.isEmpty, "\(lproj.lastPathComponent)/AppIntents.strings 缺少：\(missing)")
        }
    }

    @Test("every phrase in code is translated in every language and keeps ${applicationName}")
    func phrases() throws {
        let used = try Self.phrasesUsedInCode()
        #expect(used.count >= 3)
        for lproj in try Self.lprojDirs() {
            let table = try Self.table("AppShortcuts", in: lproj)
            let missing = used.subtracting(table.keys).sorted()
            #expect(missing.isEmpty, "\(lproj.lastPathComponent)/AppShortcuts.strings 缺少：\(missing)")
            for (key, value) in table {
                #expect(value.contains("${applicationName}"), "\(lproj.lastPathComponent): \(key) 的译文丢了 ${applicationName}")
            }
        }
    }
}
