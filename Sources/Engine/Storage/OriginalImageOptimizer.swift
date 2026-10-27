import AppKit
import ImageIO
import SwiftData
import UniformTypeIdentifiers

/// TIFF → PNG that is provably lossless, or nothing. Apps like WeChat and PixPin put
/// uncompressed TIFF on the pasteboard; the same pixels as PNG are typically 3–100× smaller.
enum LosslessPNG {
    /// Above this the two decoded bitmaps compared side by side cost too much memory.
    private static let MAX_PIXELS = 40_000_000

    /// PNG bytes that decode to exactly the TIFF's pixels, or nil when the TIFF can't make the
    /// trip: several pages (PNG holds one image), floating-point / >16-bit samples, colour models
    /// PNG lacks (CMYK, Lab), or any pixel that differs after the round trip.
    nonisolated static func convert(_ tiff: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyIsFloat] as? Bool) != true,
              ((properties[kCGImagePropertyDepth] as? Int) ?? 8) <= 16,
              let model = properties[kCGImagePropertyColorModel] as? String,
              model == (kCGImagePropertyColorModelRGB as String) || model == (kCGImagePropertyColorModelGray as String),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
              original.width * original.height <= MAX_PIXELS
        else { return nil }

        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        // From the source, not the decoded CGImage: keeps the colour profile and DPI.
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination),
              let pngSource = CGImageSourceCreateWithData(buffer, nil),
              let roundTrip = CGImageSourceCreateImageAtIndex(pngSource, 0, nil),
              samePixels(original, roundTrip)
        else { return nil }
        return buffer as Data
    }

    /// Rows compared per pass: a few MB of bitmap instead of two full-size 16-bit copies.
    private static let BAND_ROWS = 256

    /// Both images drawn into identical 16-bit RGBA bitmaps in `a`'s own colour space, so
    /// drawing `a` converts nothing: equal bytes mean equal pixels, and a PNG that lost or
    /// changed the profile gets converted on the way in and no longer matches.
    nonisolated static func samePixels(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        let space = a.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let space else { return false }
        var top = 0
        while top < a.height {
            let rows = min(BAND_ROWS, a.height - top)
            guard let first = render(a, in: space, top: top, rows: rows),
                  let second = render(b, in: space, top: top, rows: rows),
                  first == second
            else { return false }
            top += rows
        }
        return true
    }

    /// Image rows `top ..< top + rows` (counted from the top) as a bitmap of that height.
    private nonisolated static func render(_ image: CGImage, in space: CGColorSpace, top: Int, rows: Int) -> Data? {
        let bytesPerRow = image.width * 8
        guard let context = CGContext(
                data: nil, width: image.width, height: rows, bitsPerComponent: 16,
                bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
              ),
              let pixels = context.data
        else { return nil }
        // Core Graphics counts y from the bottom: shift the image down so the band lands in view.
        let y = -CGFloat(image.height - top - rows)
        context.draw(image, in: CGRect(x: 0, y: y, width: CGFloat(image.width), height: CGFloat(image.height)))
        return Data(bytes: pixels, count: bytesPerRow * rows)
    }
}

/// Swaps cached TIFF originals for lossless PNGs, one image at a time in the background, while
/// the storage page's switch is on: fresh captures right after the copy, existing ones after
/// launch and whenever the switch is turned on. Only ever touches PasteMemo's own copies in the
/// Originals cache — a Finder copy's file is the user's and is never converted.
@MainActor
final class OriginalImageOptimizer: ObservableObject {
    static let shared = OriginalImageOptimizer()

    nonisolated static let ENABLED_KEY = "optimizeTIFFOriginals"

    /// On unless turned off: the conversion is verified lossless.
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: ENABLED_KEY) as? Bool ?? true
    }

    struct Outcome: Equatable {
        var converted = 0
        /// Can't become PNG without loss; stays TIFF.
        var kept = 0
        var savedBytes: Int64 = 0
    }

    struct Progress: Equatable {
        var done: Int
        var total: Int
    }

    /// The batch running now, if any (launch pass or the switch turned on).
    @Published private(set) var progress: Progress?
    @Published private(set) var lastOutcome: Outcome?

    /// A fresh capture's TIFF may still be read by whoever handles the copy (automation
    /// outputs, OCR) — give them a moment before swapping the file underneath.
    private static let CAPTURE_DELAY: Duration = .seconds(3)
    /// A fresh capture's TIFF lingers after the swap for readers that resolved the old path
    /// just before it. A quit in between leaves it unreferenced, and the launch sweep removes it.
    /// Converting old clips frees the space right away.
    private static let TIFF_REMOVAL_DELAY: Duration = .seconds(30)
    /// Launch is busy enough; existing TIFFs can wait.
    private static let LAUNCH_DELAY: Duration = .seconds(15)

    private enum Result {
        case converted(saved: Int64)
        case unconvertible
        /// The clip is gone, points elsewhere, or the file vanished: nothing to do any more.
        case notApplicable
    }

    private var tail: Task<Void, Never>?
    /// TIFFs that can't become PNG losslessly, so they aren't retried or offered again.
    /// Per launch: a retry after restart costs one decode each.
    private(set) var unconvertiblePaths: Set<String> = []

    private init() {}

    /// Queues a just-captured clip's TIFF original.
    func enqueueCaptured(itemID: String, path: String) {
        guard Self.isEnabled, path.lowercased().hasSuffix(".tiff") else { return }
        enqueue {
            try? await Task.sleep(for: Self.CAPTURE_DELAY)
            guard Self.isEnabled else { return }
            _ = await self.convert(itemID: itemID, tiffPath: path, removeTIFFAfter: Self.TIFF_REMOVAL_DELAY)
        }
    }

    /// Existing TIFF originals, a little after launch.
    func convertExistingAfterLaunch() {
        guard Self.isEnabled else { return }
        Task {
            try? await Task.sleep(for: Self.LAUNCH_DELAY)
            await convertExisting()
        }
    }

    /// Every TIFF original in the store that isn't known to be unconvertible.
    @discardableResult
    func convertExisting() async -> Outcome? {
        guard Self.isEnabled, let locations = StorageScanner.Locations.live() else { return nil }
        let skip = unconvertiblePaths
        let candidates = await Task.detached(priority: .utility) {
            StorageScanner.tiffOriginals(in: locations).filter { !skip.contains($0.path) }
        }.value
        return await convertAll(candidates)
    }

    /// Converts the listed TIFF originals one by one; stops early when the switch goes off.
    @discardableResult
    func convertAll(_ candidates: [StorageSnapshot.TIFFOriginal]) async -> Outcome? {
        guard !candidates.isEmpty else { return nil }
        return await enqueue {
            var outcome = Outcome()
            self.progress = Progress(done: 0, total: candidates.count)
            for (index, candidate) in candidates.enumerated() {
                guard Self.isEnabled else { break }
                switch await self.convert(itemID: candidate.itemID, tiffPath: candidate.path, removeTIFFAfter: .zero) {
                case .converted(let saved):
                    outcome.converted += 1
                    outcome.savedBytes += saved
                case .unconvertible:
                    outcome.kept += 1
                case .notApplicable:
                    break
                }
                self.progress = Progress(done: index + 1, total: candidates.count)
            }
            self.progress = nil
            if outcome.converted > 0 || outcome.kept > 0 { self.lastOutcome = outcome }
            return outcome
        }.value
    }

    /// Runs `work` after everything queued before it — one decode at a time keeps memory flat
    /// when a burst of large TIFFs arrives.
    @discardableResult
    private func enqueue<T: Sendable>(_ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return task
    }

    private func convert(itemID: String, tiffPath: String, removeTIFFAfter delay: Duration) async -> Result {
        guard let directory = ClipboardManager.originalsCacheDirectory(),
              StorageCleaner.isInside(tiffPath, directory: directory.standardizedFileURL.path)
        else { return .notApplicable }
        let attempt = await Task.detached(priority: .utility) { () -> (url: URL, saved: Int64)?? in
            guard let tiff = try? Data(contentsOf: URL(fileURLWithPath: tiffPath)) else { return .some(nil) }
            guard let png = LosslessPNG.convert(tiff) else { return nil }
            let url = directory.appendingPathComponent("\(UUID().uuidString).png")
            guard (try? png.write(to: url, options: .atomic)) != nil else { return .some(nil) }
            return (url, Int64(tiff.count - png.count))
        }.value
        guard let attempt else {
            unconvertiblePaths.insert(tiffPath)
            return .unconvertible
        }
        guard let written = attempt else { return .notApplicable }

        // The clip may be gone (perhaps waiting on the main window's undo toast, which would
        // restore it with the TIFF path) or point elsewhere by now: the TIFF still belongs to
        // whoever references it, so only the new PNG is dropped.
        guard let context = ClipboardManager.shared.modelContainer?.mainContext,
              let item = try? context.fetch(FetchDescriptor<ClipItem>(predicate: #Predicate { $0.itemID == itemID })).first,
              !item.isDeleted, item.originalImageFilePath == tiffPath
        else {
            try? FileManager.default.removeItem(at: written.url)
            return .notApplicable
        }
        item.originalImageFilePath = written.url.path
        do {
            try context.save()
        } catch {
            item.originalImageFilePath = tiffPath
            try? FileManager.default.removeItem(at: written.url)
            return .notApplicable
        }
        if delay == .zero {
            StorageCleaner.deleteCachedOriginals([tiffPath])
        } else {
            Task {
                try? await Task.sleep(for: delay)
                StorageCleaner.deleteCachedOriginals([tiffPath])
            }
        }
        return .converted(saved: written.saved)
    }
}
