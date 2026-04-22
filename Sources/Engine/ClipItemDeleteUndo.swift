import Foundation
import SwiftData
import Combine

/// Captures every persisted field of a `ClipItem` at delete time so the
/// undo-toast can faithfully recreate the row if the user changes their mind.
/// `itemID` is preserved so anything referencing the clip by UUID (automation
/// rules, relay handles, external tracking) reconnects on restore.
struct ClipItemSnapshot {
    let itemID: String
    let content: String
    let contentTypeRaw: String
    let imageData: Data?
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
    let review: String?
    let groupName: String?
    let ocrText: String?
    let ocrStatus: String
    let ocrUpdatedAt: Date?
    let ocrErrorMessage: String?
    let ocrVersion: Int

    @MainActor
    init(from item: ClipItem) {
        itemID = item.itemID
        content = item.content
        contentTypeRaw = item.contentTypeRaw
        imageData = item.imageData
        sourceApp = item.sourceApp
        sourceAppBundleID = item.sourceAppBundleID
        isFavorite = item.isFavorite
        isPinned = item.isPinned
        isSensitive = item.isSensitive
        createdAt = item.createdAt
        lastUsedAt = item.lastUsedAt
        linkTitle = item.linkTitle
        faviconData = item.faviconData
        displayTitle = item.displayTitle
        codeLanguage = item.codeLanguage
        richTextData = item.richTextData
        richTextType = item.richTextType
        filePaths = item.filePaths
        pasteboardSnapshot = item.pasteboardSnapshot
        review = item.review
        groupName = item.groupName
        ocrText = item.ocrText
        ocrStatus = item.ocrStatus
        ocrUpdatedAt = item.ocrUpdatedAt
        ocrErrorMessage = item.ocrErrorMessage
        ocrVersion = item.ocrVersion
    }

    @MainActor
    func restore(into context: ModelContext) {
        let type = ClipContentType(rawValue: contentTypeRaw) ?? .text
        let item = ClipItem(
            content: content,
            contentType: type,
            imageData: imageData,
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
            pasteboardSnapshot: pasteboardSnapshot,
            review: review
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
}

/// Shared coordinator for the delete-with-undo flow used by MainWindow and
/// QuickPanel. Replaces the old confirm-alert interaction: one delete can be
/// undone within `undoWindow`; a new delete commits the previous one
/// (no stacking). Rendering is delegated to `ToastCenter` so the undo surface
/// remains reachable after the Quick Panel dismisses itself.
@MainActor
final class DeleteUndoCoordinator {
    static let shared = DeleteUndoCoordinator()

    struct Pending {
        let snapshots: [ClipItemSnapshot]
        /// The context used to delete — and therefore the one that must be used
        /// to reinsert so the restored items land in the same store graph.
        let context: ModelContext
    }

    private var pending: Pending?

    /// Keep the undo window long enough that a user who thought "oh wait" has
    /// time to move the pointer to the toast, but short enough that the toast
    /// doesn't feel like a permanent status bar.
    private let undoWindow: TimeInterval = 5

    private var expirationTask: Task<Void, Never>?

    private init() {}

    func scheduleUndoableDelete(items: [ClipItem], context: ModelContext) {
        guard !items.isEmpty else { return }
        // A second delete commits the first so we never have to reason about
        // multiple overlapping undos — matches the RelayUndoToast semantics.
        commitPending()

        let snapshots = items.map(ClipItemSnapshot.init(from:))
        ClipItemStore.deleteAndNotify(items, from: context)

        pending = Pending(snapshots: snapshots, context: context)

        // ToastCenter drives both visibility and the ⌘Z handler. Duration is
        // nil because this coordinator owns the 8s window and calls dismiss
        // itself when it expires (or when a new delete supersedes it); letting
        // ToastCenter auto-dismiss too would create two independent timers.
        let descriptor = ToastDescriptor(
            message: L10n.tr("delete.undo.toast", items.count),
            icon: .success,
            action: ToastAction(title: L10n.tr("action.undo"), shortcut: "⌘Z"),
            duration: nil
        )
        ToastCenter.shared.show(descriptor) { [weak self] in
            self?.undo()
        }

        expirationTask = Task { [weak self, undoWindow] in
            try? await Task.sleep(nanoseconds: UInt64(undoWindow * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.commitPending()
        }
    }

    func undo() {
        guard let pending else { return }
        expirationTask?.cancel()
        expirationTask = nil

        let wasPaused = ClipboardManager.shared.isPaused
        if !wasPaused { ClipboardManager.shared.pauseMonitoring() }

        let wasBulk = ClipItemStore.isBulkOperation
        ClipItemStore.isBulkOperation = true
        for snapshot in pending.snapshots {
            snapshot.restore(into: pending.context)
        }
        let touchesGroups = pending.snapshots.contains { ($0.groupName ?? "").isEmpty == false }
        if touchesGroups {
            ClipboardManager.shared.recalculateAllGroupCounts(context: pending.context)
        }
        ClipItemStore.isBulkOperation = wasBulk
        ClipItemStore.saveAndNotify(pending.context)

        if !wasPaused { ClipboardManager.shared.resumeMonitoring() }

        self.pending = nil
        ToastCenter.shared.dismiss()
    }

    /// Drops the undo handle without restoring. Called when the window expires
    /// or a new delete supersedes this one.
    func commitPending() {
        expirationTask?.cancel()
        expirationTask = nil
        guard pending != nil else { return }
        pending = nil
        ToastCenter.shared.dismiss()
    }
}
