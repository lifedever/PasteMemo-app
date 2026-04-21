import Foundation
import SwiftData
import Testing
@testable import PasteMemo

@Suite("Clip History List Builder")
struct ClipHistoryListBuilderTests {
    @Test("History rows flatten grouped clips into header-item sequence")
    @MainActor func makeRowsFlattensGroupsInDisplayOrder() {
        let first = ClipItem(content: "A", contentType: .text)
        let second = ClipItem(content: "B", contentType: .text)
        let third = ClipItem(content: "C", contentType: .text)

        let groups = [
            GroupedItem(group: .today, items: [first, second]),
            GroupedItem(group: .older, items: [third]),
        ]

        let rows = ClipHistoryListBuilder.makeRows(from: groups)

        #expect(rows.count == 5)
        #expect(rows[0] == .header(.today))
        #expect(rows[1] == .item(first.persistentModelID))
        #expect(rows[2] == .item(second.persistentModelID))
        #expect(rows[3] == .header(.older))
        #expect(rows[4] == .item(third.persistentModelID))
    }

    @Test("History row index map points item ids to table rows")
    @MainActor func rowIndexMapSkipsHeadersAndTracksItemRows() {
        let first = ClipItem(content: "A", contentType: .text)
        let second = ClipItem(content: "B", contentType: .text)

        let rows: [ClipHistoryListBuilder.Row] = [
            .header(.today),
            .item(first.persistentModelID),
            .header(.older),
            .item(second.persistentModelID),
        ]

        let indexMap = ClipHistoryListBuilder.rowIndexByItemID(rows: rows)

        #expect(indexMap[first.persistentModelID] == 1)
        #expect(indexMap[second.persistentModelID] == 3)
        #expect(indexMap.count == 2)
    }

    @Test("Shift range selection keeps original anchor across repeated clicks")
    @MainActor func rangeSelectionKeepsStableAnchor() {
        let first = ClipItem(content: "A", contentType: .text)
        let second = ClipItem(content: "B", contentType: .text)
        let third = ClipItem(content: "C", contentType: .text)
        let fourth = ClipItem(content: "D", contentType: .text)
        let orderedIDs = [
            first.persistentModelID,
            second.persistentModelID,
            third.persistentModelID,
            fourth.persistentModelID,
        ]

        let anchor = ClipHistorySelectionHelper.resolvedAnchor(
            existingAnchor: first.persistentModelID,
            focusedID: second.persistentModelID,
            fallbackSelectedID: second.persistentModelID,
            targetID: third.persistentModelID
        )
        let firstSelection = ClipHistorySelectionHelper.rangeSelection(
            orderedIDs: orderedIDs,
            anchorID: anchor,
            targetID: third.persistentModelID
        )
        let secondSelection = ClipHistorySelectionHelper.rangeSelection(
            orderedIDs: orderedIDs,
            anchorID: anchor,
            targetID: fourth.persistentModelID
        )

        #expect(anchor == first.persistentModelID)
        #expect(firstSelection == Set([first.persistentModelID, second.persistentModelID, third.persistentModelID]))
        #expect(secondSelection == Set(orderedIDs))
    }

    @Test("Selection anchor falls back to focused item when explicit anchor is missing")
    @MainActor func resolvedAnchorPrefersFocusedItemBeforeSelectionFallback() {
        let first = ClipItem(content: "A", contentType: .text)
        let second = ClipItem(content: "B", contentType: .text)
        let third = ClipItem(content: "C", contentType: .text)

        let anchor = ClipHistorySelectionHelper.resolvedAnchor(
            existingAnchor: nil as PersistentIdentifier?,
            focusedID: first.persistentModelID,
            fallbackSelectedID: second.persistentModelID,
            targetID: third.persistentModelID
        )

        #expect(anchor == first.persistentModelID)
    }

    @Test("Pagination helper requests load more only near bottom with remaining pages")
    func paginationRequestsLoadMoreNearBottom() {
        #expect(
            ClipHistoryPaginationHelper.shouldRequestLoadMore(
                totalRows: 20,
                lastVisibleRow: 15,
                pendingLoadMore: false,
                canLoadMore: true
            )
        )
        #expect(
            !ClipHistoryPaginationHelper.shouldRequestLoadMore(
                totalRows: 20,
                lastVisibleRow: 5,
                pendingLoadMore: false,
                canLoadMore: true
            )
        )
        #expect(
            !ClipHistoryPaginationHelper.shouldRequestLoadMore(
                totalRows: 20,
                lastVisibleRow: 15,
                pendingLoadMore: true,
                canLoadMore: true
            )
        )
        #expect(
            !ClipHistoryPaginationHelper.shouldRequestLoadMore(
                totalRows: 20,
                lastVisibleRow: 15,
                pendingLoadMore: false,
                canLoadMore: false
            )
        )
    }

    @Test("Pagination helper clears pending state when rows change or no more pages remain")
    func paginationResetsPendingStateWhenProgressStops() {
        #expect(
            ClipHistoryPaginationHelper.shouldResetPendingLoadMore(
                previousRowCount: 10,
                newRowCount: 12,
                canLoadMore: true
            )
        )
        #expect(
            ClipHistoryPaginationHelper.shouldResetPendingLoadMore(
                previousRowCount: 10,
                newRowCount: 10,
                canLoadMore: false
            )
        )
        #expect(
            !ClipHistoryPaginationHelper.shouldResetPendingLoadMore(
                previousRowCount: 10,
                newRowCount: 10,
                canLoadMore: true
            )
        )
    }
}
