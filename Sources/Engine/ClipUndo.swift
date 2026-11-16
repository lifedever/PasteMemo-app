import Foundation
import SwiftData
import Combine

/// Captures every persisted field of a `ClipItem` so an undo can bring the clip back
/// exactly: recreate it after a delete (`restore(into:)`), or put its fields back after
/// an in-place change (`apply(to:)`). `itemID` is preserved so anything referencing the
/// clip by UUID (automation rules, relay handles, external tracking) reconnects.
///
/// `hasBlobs == false`: the externally stored fields (image, favicon, rich text,
/// pasteboard snapshot) weren't read. For in-place changes that can't touch them —
/// re-pinning a few hundred selected clips mustn't pull a few hundred MB of rich text
/// into memory just to remember it. Such a snapshot leaves those fields alone.
struct ClipItemSnapshot {
    let itemID: String
    let content: String
    let contentTypeRaw: String
    let imageData: Data?
    let originalImageFilePath: String?
    let sourceApp: String?
    let sourceAppBundleID: String?
    let isFavorite: Bool
    let isPinned: Bool
    let isSensitive: Bool
    let createdAt: Date
    let lastUsedAt: Date
    let linkTitle: String?
    let faviconData: Data?
    let displayTitle: String?
    let codeLanguage: String?
    let richTextData: Data?
    let richTextType: String?
    let filePaths: String?
    let pasteboardSnapshot: Data?
    let groupName: String?
    let ocrText: String?
    let ocrStatus: String
    let ocrUpdatedAt: Date?
    let ocrErrorMessage: String?
    let ocrVersion: Int
    let hasBlobs: Bool

    @MainActor
    init(from item: ClipItem, includingBlobs: Bool = true) {
        hasBlobs = includingBlobs
        itemID = item.itemID
        content = item.content
        contentTypeRaw = item.contentTypeRaw
        imageData = includingBlobs ? item.imageData : nil
        originalImageFilePath = item.originalImageFilePath
        sourceApp = item.sourceApp
        sourceAppBundleID = item.sourceAppBundleID
        isFavorite = item.isFavorite
        isPinned = item.isPinned
        isSensitive = item.isSensitive
        createdAt = item.createdAt
        lastUsedAt = item.lastUsedAt
        linkTitle = item.linkTitle
        faviconData = includingBlobs ? item.faviconData : nil
        displayTitle = item.displayTitle
        codeLanguage = item.codeLanguage
        richTextData = includingBlobs ? item.richTextData : nil
        richTextType = item.richTextType
        filePaths = item.filePaths
        pasteboardSnapshot = includingBlobs ? item.pasteboardSnapshot : nil
        groupName = item.groupName
        ocrText = item.ocrText
        ocrStatus = item.ocrStatus
        ocrUpdatedAt = item.ocrUpdatedAt
        ocrErrorMessage = item.ocrErrorMessage
        ocrVersion = item.ocrVersion
    }

    @MainActor
    func restore(into context: ModelContext) {
        assert(hasBlobs, "a clip can only be recreated from a full snapshot")
        let type = ClipContentType(rawValue: contentTypeRaw) ?? .text
        let item = ClipItem(
            content: content,
            contentType: type,
            imageData: imageData,
            originalImageFilePath: originalImageFilePath,
            sourceApp: sourceApp,
            sourceAppBundleID: sourceAppBundleID,
            isFavorite: isFavorite,
            isPinned: isPinned,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            codeLanguage: codeLanguage,
            richTextData: richTextData,
            richTextType: richTextType,
            filePaths: filePaths,
            pasteboardSnapshot: pasteboardSnapshot
        )
        item.itemID = itemID
        item.isSensitive = isSensitive
        item.linkTitle = linkTitle
        item.faviconData = faviconData
        if let displayTitle { item.displayTitle = displayTitle }
        item.groupName = groupName
        item.ocrText = ocrText
        item.ocrStatus = ocrStatus
        item.ocrUpdatedAt = ocrUpdatedAt
        item.ocrErrorMessage = ocrErrorMessage
        item.ocrVersion = ocrVersion
        context.insert(item)
    }

    /// Put the captured fields back onto the same clip. A field is only written when it
    /// differs, so an untouched multi-MB blob isn't rewritten to external storage.
    @MainActor
    func apply(to item: ClipItem) {
        if item.content != content { item.content = content }
        if item.contentTypeRaw != contentTypeRaw { item.contentTypeRaw = contentTypeRaw }
        if hasBlobs {
            if item.imageData != imageData { item.imageData = imageData }
            if item.faviconData != faviconData { item.faviconData = faviconData }
            if item.richTextData != richTextData { item.richTextData = richTextData }
            if item.pasteboardSnapshot != pasteboardSnapshot { item.pasteboardSnapshot = pasteboardSnapshot }
        }
        if item.sourceApp != sourceApp { item.sourceApp = sourceApp }
        if item.sourceAppBundleID != sourceAppBundleID { item.sourceAppBundleID = sourceAppBundleID }
        if item.isPinned != isPinned { item.isPinned = isPinned }
        if item.isSensitive != isSensitive { item.isSensitive = isSensitive }
        if item.lastUsedAt != lastUsedAt { item.lastUsedAt = lastUsedAt }
        if item.linkTitle != linkTitle { item.linkTitle = linkTitle }
        if item.displayTitle != displayTitle { item.displayTitle = displayTitle }
        if item.codeLanguage != codeLanguage { item.codeLanguage = codeLanguage }
        if item.richTextType != richTextType { item.richTextType = richTextType }
        if item.filePaths != filePaths { item.filePaths = filePaths }
        if item.groupName != groupName { item.groupName = groupName }
    }

    /// Whether `item` still holds what was captured, in the fields an operation can change.
    @MainActor
    func matches(_ item: ClipItem) -> Bool {
        item.content == content && item.contentTypeRaw == contentTypeRaw
            && item.isPinned == isPinned && item.isSensitive == isSensitive
            && item.lastUsedAt == lastUsedAt && item.groupName == groupName
            && item.richTextType == richTextType && item.codeLanguage == codeLanguage
            && item.linkTitle == linkTitle && item.displayTitle == displayTitle
            && item.sourceAppBundleID == sourceAppBundleID && item.filePaths == filePaths
            && (!hasBlobs || (item.richTextData == richTextData && item.pasteboardSnapshot == pasteboardSnapshot
                && item.imageData == imageData && item.faviconData == faviconData))
    }
}

/// What one user operation did to the history — the clips it created, deleted and
/// changed in place — so the undo toast can put it all back. Every history-changing
/// action goes through one: delete, merge, split, a manual rule, an edit.
@MainActor
final class ClipChange {
    let context: ModelContext
    private(set) var inserted: [ClipItem] = []
    private(set) var deleted: [ClipItemSnapshot] = []
    private var modified: [(item: ClipItem, before: ClipItemSnapshot)] = []
    private var modifiedIDs: Set<PersistentIdentifier> = []

    init(context: ModelContext) {
        self.context = context
    }

    /// Call before changing a clip in place. The first call per clip wins, so the undo
    /// goes back to the state before the whole operation. `includingBlobs: false` when
    /// the change can't touch image / favicon / rich text / pasteboard snapshot (see
    /// `ClipItemSnapshot`).
    func willModify(_ item: ClipItem, includingBlobs: Bool = true) {
        guard !item.isGone, !inserted.contains(where: { $0 === item }),
              modifiedIDs.insert(item.persistentModelID).inserted else { return }
        modified.append((item, ClipItemSnapshot(from: item, includingBlobs: includingBlobs)))
    }

    /// A clip this operation creates; undo deletes it again.
    func insert(_ item: ClipItem) {
        context.insert(item)
        inserted.append(item)
    }

    /// Delete clips; undo recreates them from their snapshots.
    func delete(_ items: [ClipItem]) {
        let live = items.filter { !$0.isGone }
        guard !live.isEmpty else { return }
        deleted += live.map { ClipItemSnapshot(from: $0) }
        ClipItemStore.deleteAndNotify(live, from: context)
    }

    var hasChanges: Bool {
        !inserted.isEmpty || !deleted.isEmpty
            || modified.contains { !$0.item.isGone && !$0.before.matches($0.item) }
    }

    var deletedCount: Int { deleted.count }

    fileprivate func revert() {
        ClipboardManager.shared.beginBulkWriteHold()
        defer { ClipboardManager.shared.endBulkWriteHold() }
        let wasBulk = ClipItemStore.isBulkOperation
        ClipItemStore.isBulkOperation = true

        // Group badges count clips per group: anything that had or has a group moves them.
        // (Deleting the created clips recounts on its own.)
        let hasGroup: (String?) -> Bool = { !($0 ?? "").isEmpty }
        let touchesGroups = deleted.contains { hasGroup($0.groupName) }
            || modified.contains { hasGroup($0.before.groupName) || (!$0.item.isGone && hasGroup($0.item.groupName)) }

        let created = inserted.filter { !$0.isGone }
        if !created.isEmpty {
            ClipItemStore.deleteAndNotify(created, from: context)
        }
        for (item, before) in modified where !item.isGone {
            before.apply(to: item)
        }
        for snapshot in deleted {
            snapshot.restore(into: context)
        }
        if touchesGroups {
            ClipboardManager.shared.recalculateAllGroupCounts(context: context)
        }
        ClipItemStore.isBulkOperation = wasBulk
        ClipItemStore.saveAndNotify(context)
    }

    /// The operation is final: deleted clips' original-bytes cache files can go.
    fileprivate func commit() {
        for snapshot in deleted {
            ClipboardManager.deleteOriginalCacheFile(at: snapshot.originalImageFilePath)
        }
    }
}

/// The one undo the app keeps: the most recent history change, reachable from its toast
/// (button or ⌘Z) for `UNDO_WINDOW` seconds. A new change commits the previous one —
/// no stacking. Rendering is delegated to `ToastCenter` so the undo stays reachable
/// after the Quick Panel dismisses itself.
@MainActor
final class ClipUndoCoordinator {
    static let shared = ClipUndoCoordinator()

    static let UNDO_WINDOW: TimeInterval = 8
    /// Tests run without a window server; they turn the toast off.
    static var showsToast = true

    private var pending: ClipChange?
    private var expirationTask: Task<Void, Never>?

    private init() {}

    /// Run `body` as one undoable change. `body` returns the toast message, or nil when
    /// it decided not to do anything; no toast either when nothing actually changed.
    /// `undoFromOtherApps`: ⌘Z also works while another app is in front (deletes only —
    /// see `scheduleUndoableDelete`).
    @discardableResult
    func perform(
        context: ModelContext,
        undoFromOtherApps: Bool = false,
        _ body: (ClipChange) -> String?
    ) -> ClipChange {
        let change = ClipChange(context: context)
        let message = body(change)
        ClipItemStore.saveAndNotify(context)
        if let message {
            register(change, message: message, undoFromOtherApps: undoFromOtherApps)
        }
        return change
    }

    /// Offer the undo for a change built step by step (the rule executor's path).
    /// Does nothing when the change left the history as it was.
    func register(_ change: ClipChange, message: String, undoFromOtherApps: Bool = false) {
        guard change.hasChanges else { return }
        commitPending()
        pending = change
        expirationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.UNDO_WINDOW))
            guard !Task.isCancelled else { return }
            self?.commitPending()
        }
        guard Self.showsToast else { return }
        // ToastCenter drives visibility and the ⌘Z monitors; this coordinator owns the
        // window and dismisses the toast when it runs out.
        let descriptor = ToastDescriptor(
            message: message,
            icon: .success,
            action: ToastAction(title: L10n.tr("action.undo"), shortcut: "⌘Z", worksInOtherApps: undoFromOtherApps),
            duration: nil
        )
        ToastCenter.shared.show(descriptor) { [weak self] in
            self?.undo()
        }
    }

    /// Delete with the undo toast. ⌘Z works from other apps too, which paste-and-destroy
    /// relies on: the target app's own ⌘Z takes the paste back while ours restores the clip.
    func scheduleUndoableDelete(items: [ClipItem], context: ModelContext) {
        guard !items.isEmpty else { return }
        perform(context: context, undoFromOtherApps: true) { change in
            change.delete(items)
            return L10n.tr("delete.undo.toast", change.deletedCount)
        }
    }

    func undo() {
        guard let change = pending else { return }
        expirationTask?.cancel()
        expirationTask = nil
        pending = nil
        change.revert()
        if Self.showsToast { ToastCenter.shared.dismiss() }
    }

    /// Drops the undo without reverting — the change is now permanent.
    func commitPending() {
        expirationTask?.cancel()
        expirationTask = nil
        guard let change = pending else { return }
        pending = nil
        change.commit()
        if Self.showsToast { ToastCenter.shared.dismiss() }
    }
}
