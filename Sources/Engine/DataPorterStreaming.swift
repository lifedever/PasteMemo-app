import Compression
import Foundation
import SwiftData

/// Splits an export's JSON into its `items` one at a time, so an import never holds the whole
/// document: decoded in one go, a backup that carries the cached originals takes about three
/// times its size in memory. Everything outside `items` (version, groups, rules — small) is
/// kept as a skeleton document with `"items":[]`.
///
/// Works on raw UTF-8 bytes. Braces and brackets inside strings are skipped by tracking quotes
/// and backslash escapes; nothing else about the JSON needs understanding.
struct ExportItemSplitter {
    private enum Mode { case skeleton, itemsArray, item }

    private(set) var skeleton = Data()
    private var mode = Mode.skeleton
    private var item = Data()
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var capturingKey = false
    private var keyBytes: [UInt8] = []
    private var lastString: [UInt8] = []
    private var lastKey: [UInt8] = []
    private var itemsDone = false

    private static let QUOTE = UInt8(ascii: "\"")
    private static let BACKSLASH = UInt8(ascii: "\\")
    private static let COLON = UInt8(ascii: ":")
    private static let OPEN_OBJECT = UInt8(ascii: "{")
    private static let CLOSE_OBJECT = UInt8(ascii: "}")
    private static let OPEN_ARRAY = UInt8(ascii: "[")
    private static let CLOSE_ARRAY = UInt8(ascii: "]")
    private static let ITEMS_KEY = Array("items".utf8)

    /// Feeds the next stretch of the document; `emit` gets every item completed within it.
    mutating func feed(_ chunk: Data, emit: (Data) throws -> Void) rethrows {
        try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var segmentStart = 0
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == Self.BACKSLASH {
                        escaped = true
                    } else if byte == Self.QUOTE {
                        inString = false
                        if capturingKey {
                            capturingKey = false
                            lastString = keyBytes
                        }
                    } else if capturingKey {
                        keyBytes.append(byte)
                    }
                    index += 1
                    continue
                }
                switch mode {
                case .item:
                    switch byte {
                    case Self.QUOTE: inString = true
                    case Self.OPEN_OBJECT, Self.OPEN_ARRAY: depth += 1
                    case Self.CLOSE_OBJECT, Self.CLOSE_ARRAY:
                        depth -= 1
                        if depth == 2 {
                            item.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[segmentStart...index]))
                            try emit(item)
                            item.removeAll(keepingCapacity: true)
                            mode = .itemsArray
                        }
                    default: break
                    }
                case .itemsArray:
                    // Between items: commas and whitespace are dropped.
                    if byte == Self.OPEN_OBJECT {
                        mode = .item
                        depth = 3
                        segmentStart = index
                    } else if byte == Self.CLOSE_ARRAY {
                        mode = .skeleton
                        depth = 1
                        itemsDone = true
                        segmentStart = index
                    }
                case .skeleton:
                    switch byte {
                    case Self.QUOTE:
                        inString = true
                        if depth == 1 {
                            capturingKey = true
                            keyBytes.removeAll(keepingCapacity: true)
                        }
                    case Self.COLON where depth == 1:
                        lastKey = lastString
                    case Self.OPEN_OBJECT, Self.OPEN_ARRAY:
                        depth += 1
                        if byte == Self.OPEN_ARRAY, depth == 2, !itemsDone, lastKey == Self.ITEMS_KEY {
                            skeleton.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[segmentStart...index]))
                            mode = .itemsArray
                        }
                    case Self.CLOSE_OBJECT, Self.CLOSE_ARRAY:
                        depth -= 1
                    default: break
                    }
                }
                index += 1
            }
            // Whatever the current mode is still collecting carries over to the next chunk.
            switch mode {
            case .skeleton: skeleton.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[segmentStart...]))
            case .item: item.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[segmentStart...]))
            case .itemsArray: break
            }
        }
    }

    /// True once the document closed with no item left half-read.
    var isComplete: Bool { mode == .skeleton && depth == 0 && !inString }
}

/// Hands out an export's JSON in pieces: zlib-compressed (every file since compression was
/// added) is inflated as it goes, a plain-JSON file from before that is sliced as is.
final class ExportChunkReader {
    private static let CHUNK = 256 * 1024
    private let data: Data
    private var filter: InputFilter<Data>?
    private var offset = 0
    private var pendingFirst: Data?

    /// `data` is the file minus its envelope (what `DataPorterCrypto.decrypt` returns).
    init(_ data: Data) throws {
        self.data = data
        // Compressed unless the first inflated bytes fail or don't start a JSON object — a
        // plain file starting "{" can still look like a valid deflate block for a while.
        if let filter = try? Self.makeFilter(data),
           let first = try? filter.readData(ofLength: Self.CHUNK),
           first.first(where: { !Self.isWhitespace($0) }) == UInt8(ascii: "{") {
            self.filter = filter
            pendingFirst = first
        }
    }

    func next() throws -> Data? {
        if let first = pendingFirst {
            pendingFirst = nil
            return first
        }
        if let filter {
            guard let page = try filter.readData(ofLength: Self.CHUNK), !page.isEmpty else { return nil }
            return page
        }
        guard offset < data.count else { return nil }
        let start = data.startIndex + offset
        let end = min(start + Self.CHUNK, data.endIndex)
        offset += end - start
        return data[start..<end]
    }

    private static func makeFilter(_ data: Data) throws -> InputFilter<Data> {
        var position = data.startIndex
        return try InputFilter(.decompress, using: .zlib) { (length: Int) -> Data? in
            guard position < data.endIndex else { return Data() }
            let end = min(position + length, data.endIndex)
            defer { position = end }
            return data[position..<end]
        }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }
}

extension DataPorter {
    enum StreamingImportError: LocalizedError {
        case truncated
        var errorDescription: String? { "The file is incomplete or damaged." }
    }

    /// First pass, off the main actor: how many items, and the skeleton (version, groups, rules).
    nonisolated static func scanExport(_ data: Data) throws -> (itemCount: Int, header: ExportPayload) {
        let reader = try ExportChunkReader(data)
        var splitter = ExportItemSplitter()
        var count = 0
        while let chunk = try reader.next() {
            splitter.feed(chunk) { _ in count += 1 }
        }
        guard splitter.isComplete else { throw StreamingImportError.truncated }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (count, try decoder.decode(ExportPayload.self, from: splitter.skeleton))
    }

    /// Imports an export without holding it decoded in memory: groups and rules first, then the
    /// items as they stream past, saved every `batchSize`. `data` is the file minus its
    /// envelope. Behaves like `importItems(payload:into:progress:)` otherwise.
    @MainActor
    static func importStreaming(
        _ data: Data,
        into context: ModelContext,
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async throws -> ImportResult {
        let (total, header) = try await Task.detached(priority: .userInitiated) { try scanExport(data) }.value
        let groupResult = importGroups(header.groups ?? [], into: context)
        let ruleResult = importRules(header.rules ?? [], into: context)
        progress(0, total)
        await Task.yield()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let reader = try ExportChunkReader(data)
        var splitter = ExportItemSplitter()
        var imported = 0
        var skipped = 0
        var seen = 0
        let deduplicator = ImportDeduplicator(context: context)
        let batchSize = 25
        let yieldEvery = 5

        while let chunk = try reader.next() {
            var ready: [Data] = []
            splitter.feed(chunk) { ready.append($0) }
            for itemData in ready {
                let exportItem = try decoder.decode(ExportItem.self, from: itemData)
                if deduplicator.mergeIfDuplicate(exportItem) {
                    skipped += 1
                } else {
                    deduplicator.add(insertClipItem(from: exportItem, into: context))
                    imported += 1
                }
                seen += 1
                if seen % batchSize == 0 {
                    try context.save()
                }
                if seen % yieldEvery == 0 {
                    progress(min(seen, total), total)
                    await Task.yield()
                }
            }
        }
        try context.save()
        progress(total, total)

        recalculateGroupCounts(in: context)
        try context.save()
        return ImportResult(imported: imported, skipped: skipped, importedGroups: groupResult, importedRules: ruleResult)
    }

    /// Writes a `.pastememo` export to `url` by streaming every clip through the compressor
    /// (original images included), instead of building the whole document in memory first.
    @MainActor
    static func writeExportFile(
        clipItems: [ClipItem],
        groups: [SmartGroup],
        rules: [AutomationRule],
        to url: URL,
        password: String?,
        progress: @MainActor @escaping (_ current: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pastememo-export-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }

        if let password, !password.isEmpty {
            try await encodeAndCompress(clipItems: clipItems, groups: groups, rules: rules, to: temp, progress: progress)
            // AES-GCM seals one buffer; the compressed file is mapped rather than read in.
            try await Task.detached(priority: .userInitiated) {
                let compressed = try Data(contentsOf: temp, options: .mappedIfSafe)
                try DataPorterCrypto.encrypt(data: compressed, password: password).write(to: url, options: .atomic)
            }.value
        } else {
            try await encodeAndCompress(
                clipItems: clipItems, groups: groups, rules: rules, to: temp,
                header: DataPorterCrypto.wrapPlaintext(Data()), progress: progress
            )
            // The save panel already confirmed replacing; a move also works across volumes
            // (external drive), where `replaceItemAt` can refuse.
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }
}
