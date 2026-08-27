import Foundation
import Testing
@testable import PasteMemo

@Suite("FileAvailability probing")
struct FileAvailabilityTests {

    // MARK: - Single path

    @Test("A readable file is available")
    func readableFile() {
        #expect(FileAvailability.check("/usr/bin/swift") == .available)
    }

    @Test("A path that isn't there reads as missing, not denied")
    func absentFile() {
        #expect(FileAvailability.check("/nope/does/not/exist.mp4") == .missing)
    }

    @Test("Directories open fine")
    func directory() {
        #expect(FileAvailability.check(NSHomeDirectory()) == .available)
    }

    @Test("Empty path is missing")
    func emptyPath() {
        #expect(FileAvailability.check("") == .missing)
    }

    /// The whole point of the type: a TCC-refused read must NOT look like a deleted file.
    /// `~/Library/Application Support/com.apple.TCC` needs Full Disk Access, which the test
    /// runner doesn't have — if it ever does, this reports `.available` and the case is moot.
    @Test("A TCC-protected path is denied, not missing")
    func tccProtected() {
        let tcc = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let result = FileAvailability.check(tcc)
        #expect(result != .missing, "TCC denial must be distinguishable from a missing file")
    }

    /// Without `O_NONBLOCK`, opening a FIFO read-only blocks until someone opens the write
    /// end — i.e. forever, hanging whichever view probed it. Clips can hold any path the
    /// user copied, so this is reachable.
    @Test("Opening a FIFO returns instead of blocking forever", .timeLimit(.minutes(1)))
    func fifoDoesNotBlock() throws {
        let path = NSTemporaryDirectory() + "pm_fileavailability_fifo"
        unlink(path)
        #expect(mkfifo(path, 0o644) == 0)
        defer { unlink(path) }

        #expect(FileAvailability.check(path) == .available)
    }

    // MARK: - Multi path

    @Test("All-absent paths are missing")
    func multiAllMissing() {
        #expect(FileAvailability.check(paths: ["/a/x", "/b/y"]) == .missing)
    }

    @Test("One readable path wins")
    func multiAnyReadable() {
        #expect(FileAvailability.check(paths: ["/a/x", "/usr/bin/swift"]) == .available)
    }

    @Test("Empty list is missing")
    func multiEmpty() {
        #expect(FileAvailability.check(paths: []) == .missing)
    }

    /// A Finder copy can carry thousands of paths (one report had ~2000) and this runs only
    /// when none were readable — probing every one would be pure wasted I/O.
    @Test("A huge path list is capped rather than probed end to end")
    func multiIsCapped() {
        let many = (0..<2000).map { "/nope/f\($0)" }
        let started = Date()
        #expect(FileAvailability.check(paths: many) == .missing)
        #expect(Date().timeIntervalSince(started) < 0.5)
    }
}
