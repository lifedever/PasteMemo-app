import SwiftUI

struct QuickClipRow: View {
    let item: ClipItem
    let isSelected: Bool
    var shortcutIndex: Int? = nil
    var searchText: String = ""
    var sortMode: HistorySortMode = .lastUsed

    var body: some View {
        HStack(spacing: 0) {
            ClipRow(item: item, isSelected: isSelected, showGroupLabel: false, searchText: searchText, sortMode: sortMode)
            Spacer(minLength: 4)
            if let index = shortcutIndex {
                shortcutBadge(index)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            isSelected
                ? Color.primary.opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .padding(.vertical, 1)
    }

    private func shortcutBadge(_ index: Int) -> some View {
        Text("⌘\(index)")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
    }
}
