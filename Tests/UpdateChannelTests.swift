import Foundation
import Testing
@testable import PasteMemo

@Suite("LatestInfo JSON decoding")
struct LatestInfoDecodingTests {

    @Test("Old latest.json (no beta field) still decodes")
    func legacyJsonNoBeta() throws {
        let json = """
        {
          "version": "1.6.8",
          "notes_zh": "中文",
          "notes_en": "English",
          "downloads": {
            "arm64": "https://example.com/arm.dmg",
            "x86_64": "https://example.com/x86.dmg"
          },
          "checksums": {
            "arm64": {"url": "https://example.com/arm.dmg", "size": 123, "sha256": "aaa"},
            "x86_64": {"url": "https://example.com/x86.dmg", "size": 456, "sha256": "bbb"}
          }
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(LatestInfo.self, from: json)
        #expect(info.version == "1.6.8")
        #expect(info.beta == nil)
        #expect(info.downloads["arm64"]?.url == "https://example.com/arm.dmg")
        #expect(info.checksums?["arm64"]?.sha256 == "aaa")
    }

    @Test("New latest.json with nested beta field decodes")
    func jsonWithBeta() throws {
        let json = """
        {
          "version": "1.6.9",
          "notes_zh": "稳定版",
          "notes_en": "Stable",
          "downloads": {
            "arm64": "https://example.com/stable-arm.dmg",
            "x86_64": "https://example.com/stable-x86.dmg"
          },
          "checksums": {
            "arm64": {"url": "https://example.com/stable-arm.dmg", "size": 100, "sha256": "s-arm"},
            "x86_64": {"url": "https://example.com/stable-x86.dmg", "size": 200, "sha256": "s-x86"}
          },
          "beta": {
            "version": "1.7.0-beta.1",
            "notes_zh": "Beta 中文",
            "notes_en": "Beta English",
            "downloads": {
              "arm64": "https://example.com/beta-arm.dmg",
              "x86_64": "https://example.com/beta-x86.dmg"
            },
            "checksums": {
              "arm64": {"url": "https://example.com/beta-arm.dmg", "size": 110, "sha256": "b-arm"},
              "x86_64": {"url": "https://example.com/beta-x86.dmg", "size": 220, "sha256": "b-x86"}
            }
          }
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(LatestInfo.self, from: json)
        #expect(info.version == "1.6.9")
        #expect(info.beta?.version == "1.7.0-beta.1")
        #expect(info.beta?.notesZh == "Beta 中文")
        #expect(info.beta?.checksums?["arm64"]?.sha256 == "b-arm")
    }

    @Test("Plain string download URL (legacy short format) still decodes")
    func legacyDownloadStringFormat() throws {
        // Older feeds had `"arm64": "url"` (string) before checksums were added.
        let json = """
        {
          "version": "1.5.0",
          "downloads": {
            "arm64": "https://example.com/old.dmg",
            "x86_64": "https://example.com/old-x86.dmg"
          }
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(LatestInfo.self, from: json)
        #expect(info.downloads["arm64"]?.url == "https://example.com/old.dmg")
        #expect(info.downloads["arm64"]?.size == nil)
        #expect(info.downloads["arm64"]?.sha256 == nil)
    }
}

@Suite("pickChannel selection logic")
struct PickChannelTests {

    private func makeInfo(stable: String, beta: String?) -> LatestInfo {
        // Build via JSON to avoid having to construct DownloadEntry directly
        // (its initializer is from(decoder:) only).
        let betaBlock: String
        if let b = beta {
            betaBlock = """
            ,
              "beta": {
                "version": "\(b)",
                "notes_zh": "b zh",
                "notes_en": "b en",
                "downloads": { "arm64": "https://example.com/beta.dmg" }
              }
            """
        } else {
            betaBlock = ""
        }
        let json = """
        {
          "version": "\(stable)",
          "notes_zh": "s zh",
          "notes_en": "s en",
          "downloads": { "arm64": "https://example.com/stable.dmg" }
          \(betaBlock)
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(LatestInfo.self, from: json)
    }

    @Test("useBeta=false always returns stable")
    func stableChannel() {
        let info = makeInfo(stable: "1.6.9", beta: "1.7.0-beta.1")
        let result = pickChannel(info: info, useBeta: false)
        #expect(result.version == "1.6.9")
    }

    @Test("Beta channel returns beta when strictly newer than stable")
    func betaWinsWhenNewer() {
        let info = makeInfo(stable: "1.6.9", beta: "1.7.0-beta.1")
        let result = pickChannel(info: info, useBeta: true)
        #expect(result.version == "1.7.0-beta.1")
    }

    @Test("Beta channel falls back to stable once promoted")
    func betaFallsBackAfterPromotion() {
        // Edge case the promotion-cleanup logic in publish-release.sh tries to
        // prevent, but we still want client-side defense: if a stale CDN copy
        // shows beta == stable (or beta < stable), the client must NOT
        // re-suggest the beta version.
        let info = makeInfo(stable: "1.7.0", beta: "1.7.0-beta.3")
        let result = pickChannel(info: info, useBeta: true)
        #expect(result.version == "1.7.0", "beta < stable → must use stable")
    }

    @Test("Beta channel falls back to stable when beta exactly equals stable")
    func betaFallsBackOnEqualVersion() {
        let info = makeInfo(stable: "1.7.0", beta: "1.7.0")
        let result = pickChannel(info: info, useBeta: true)
        #expect(result.version == "1.7.0")
    }

    @Test("Beta channel without beta field returns stable")
    func betaChannelWithoutBetaField() {
        let info = makeInfo(stable: "1.6.9", beta: nil)
        let result = pickChannel(info: info, useBeta: true)
        #expect(result.version == "1.6.9")
    }

    @Test("Beta channel selects newer beta of next major")
    func betaOfNextMajor() {
        let info = makeInfo(stable: "1.6.9", beta: "2.0.0-alpha.1")
        let result = pickChannel(info: info, useBeta: true)
        #expect(result.version == "2.0.0-alpha.1")
    }
}

@Suite("Localization completeness")
@MainActor
struct LocalizationCompletenessTests {

    /// Every shipped language must declare both Beta-channel keys, otherwise
    /// the toggle in Settings → About falls back to its raw key (an ugly
    /// debug string visible to users) for that language.
    @Test("All bundled languages declare settings.includeBetaChannel keys")
    func everyLanguageHasBetaChannelKeys() throws {
        // Bundle.module.localizations is empty on the SPM-generated resource
        // bundle — enumerate .lproj directories directly instead.
        let bundle = L10n.resourceBundle
        let lprojURLs = bundle.urls(forResourcesWithExtension: "lproj", subdirectory: nil) ?? []
        let langs = lprojURLs
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0 != "Base" }
        #expect(!langs.isEmpty, "No .lproj directories found in resource bundle — test setup wrong")

        let requiredKeys = [
            "settings.includeBetaChannel",
            "settings.includeBetaChannel.hint",
            "update.available.beta.title",
            "update.beta.warning",
        ]

        for lprojURL in lprojURLs {
            let lang = lprojURL.deletingPathExtension().lastPathComponent
            if lang == "Base" { continue }
            let stringsURL = lprojURL.appendingPathComponent("Localizable.strings")
            guard let dict = NSDictionary(contentsOf: stringsURL) as? [String: String] else {
                Issue.record("Could not read Localizable.strings for '\(lang)' at \(stringsURL.path)")
                continue
            }
            for key in requiredKeys {
                let value = dict[key]
                #expect(value != nil, "Language '\(lang)' is missing key '\(key)'")
                #expect(value?.isEmpty == false, "Language '\(lang)' has empty value for '\(key)'")
            }
        }
    }
}
