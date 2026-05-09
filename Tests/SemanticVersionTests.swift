import Testing
@testable import PasteMemo

@Suite("SemanticVersion comparison")
struct SemanticVersionTests {

    // MARK: - Core version comparison

    @Test("Higher patch is newer")
    func patchBump() {
        #expect(SemanticVersion.isNewer(remote: "1.6.9", current: "1.6.8"))
        #expect(!SemanticVersion.isNewer(remote: "1.6.8", current: "1.6.9"))
    }

    @Test("Higher minor outranks lower minor")
    func minorBump() {
        #expect(SemanticVersion.isNewer(remote: "1.7.0", current: "1.6.99"))
    }

    @Test("Equal versions are not newer")
    func equal() {
        #expect(!SemanticVersion.isNewer(remote: "1.6.8", current: "1.6.8"))
    }

    @Test("Different segment counts compare as if missing parts are zero")
    func paddedZero() {
        #expect(SemanticVersion.compare("1.6", "1.6.0") == 0)
        #expect(SemanticVersion.compare("2", "1.99.99") > 0)
    }

    // MARK: - Pre-release precedence (the bug we are fixing)

    @Test("Release version is newer than its pre-release")
    func releaseBeatsPrerelease() {
        #expect(SemanticVersion.isNewer(remote: "1.7.0", current: "1.7.0-beta.1"))
        #expect(!SemanticVersion.isNewer(remote: "1.7.0-beta.1", current: "1.7.0"))
    }

    @Test("Pre-release of next version still beats current release")
    func prereleaseBeatsOlderRelease() {
        // 1.7.0-beta.1 > 1.6.9 because core 1.7.0 > 1.6.9
        #expect(SemanticVersion.isNewer(remote: "1.7.0-beta.1", current: "1.6.9"))
    }

    @Test("Higher pre-release number is newer")
    func prereleaseNumeric() {
        #expect(SemanticVersion.isNewer(remote: "1.7.0-beta.2", current: "1.7.0-beta.1"))
    }

    @Test("Numeric pre-release ids compare numerically not lexically")
    func prereleaseNumericNotLexical() {
        // Lexical "10" < "2"; numeric 10 > 2. SemVer §11.4 mandates numeric.
        #expect(SemanticVersion.isNewer(remote: "1.7.0-beta.10", current: "1.7.0-beta.2"))
    }

    @Test("Alpha < beta lexically")
    func prereleaseLexical() {
        #expect(SemanticVersion.isNewer(remote: "1.7.0-beta.1", current: "1.7.0-alpha.1"))
    }

    @Test("Numeric identifier ranks below alphanumeric")
    func numericBelowAlpha() {
        // SemVer §11.4: when one identifier is numeric and the other isn't,
        // numeric < alphanumeric.
        #expect(SemanticVersion.compare("1.0.0-1", "1.0.0-alpha") < 0)
    }

    @Test("Longer pre-release id list is newer when prefix equal")
    func longerPrereleaseWins() {
        #expect(SemanticVersion.isNewer(remote: "1.7.0-beta.1.fix", current: "1.7.0-beta.1"))
    }

    // MARK: - Edge cases

    @Test("Same pre-release equals zero")
    func samePre() {
        #expect(SemanticVersion.compare("1.7.0-beta.1", "1.7.0-beta.1") == 0)
    }

    @Test("Garbage segments treated as zero")
    func garbage() {
        // Don't crash; missing or non-numeric core segments degrade to 0.
        _ = SemanticVersion.compare("1.x.0", "1.0.0")
    }
}
