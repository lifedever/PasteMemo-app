import SwiftUI

struct QuickClipRow: View {
    let item: ClipItem
    let isSelected: Bool
    var shortcutIndex: Int? = nil
    var searchText: String = ""
    var compact: Bool = false
    /// 多选时这一行第几个粘贴（按勾选顺序）
    var pickNumber: Int? = nil

    var body: some View {
        HStack(spacing: 0) {
            ClipRow(item: item, isSelected: isSelected, showGroupLabel: false, searchText: searchText, compact: compact)
            Spacer(minLength: 4)
            if let pickNumber {
                pickBadge(pickNumber)
                    .padding(.trailing, shortcutIndex == nil ? 0 : 6)
            }
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

    private func pickBadge(_ number: Int) -> some View {
        Text("\(number)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(minWidth: 17, minHeight: 17)
            .background(Color.accentColor, in: Circle())
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
