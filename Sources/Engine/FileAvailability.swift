import Foundation

/// Why a file referenced by a clip can't be read right now.
///
/// `FileManager.fileExists` collapses both failure modes into `false` — a TCC denial
/// makes `stat` fail exactly like a missing file does — so every unreadable clip used
/// to render the same gray placeholder. The two need opposite reactions from the user
/// though: a missing file is gone for good, a refused one is a permission toggle away
/// from working. Only the raw `errno` tells them apart.
enum FileAvailability: Equatable {
    /// On disk and openable by this process.
    case available
    /// No such file. Typically a self-cleaning temp dir (CleanShot's media folder,
    /// WeChat's container, browser downloads) that purged it after the copy.
    case missing
    /// Present but the OS refused the read — TCC ("Files and Folders" / "Full Disk
    /// Access") or plain POSIX permissions.
    case denied

    var isAvailable: Bool { self == .available }
}

extension FileAvailability {
    /// Opens the path read-only for a definitive answer. `open(2)` is the cheapest call
    /// that separates EPERM/EACCES from ENOENT — `stat` can't, because TCC denies that
    /// too. Directories open fine with `O_RDONLY`. No bytes are read, but it's still a
    /// syscall: keep it off the main thread when checking many paths at once.
    static func check(_ path: String) -> FileAvailability {
        guard !path.isEmpty else { return .missing }
        // O_NONBLOCK matters: opening a FIFO read-only blocks until a writer appears, and a
        // clip can hold whatever path the user copied. No effect on regular files or dirs.
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        if fd >= 0 {
            close(fd)
            return .available
        }
        switch errno {
        case EACCES, EPERM: return .denied
        default: return .missing
        }
    }

    /// How many paths a multi-file verdict will probe. A single Finder copy can carry
    /// thousands (one report had ~2000) and this runs when *none* of them were readable —
    /// the first handful already establishes why, so the rest is wasted I/O.
    private static let maxProbedPaths = 16

    /// Verdict for a multi-file clip: `.available` as soon as any path opens, otherwise
    /// `.denied` when at least one was refused (that's the actionable case) and
    /// `.missing` when they're simply all gone.
    static func check(paths: [String]) -> FileAvailability {
        var sawDenied = false
        for path in paths.prefix(maxProbedPaths) {
            switch check(path) {
            case .available: return .available
            case .denied: sawDenied = true
            case .missing: continue
            }
        }
        return sawDenied ? .denied : .missing
    }
}
