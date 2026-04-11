import SwiftUI

enum SnippetRowLayout {
    case standard
    case compact
}

struct SnippetRow: View {
    let snippet: SnippetItem
    let isSelected: Bool
    var showScopeBadge: Bool = false
    var layoutStyle: SnippetRowLayout = .standard

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: snippet.contentType.icon)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: isCompactLayout ? 3 : 4) {
                HStack(spacing: 6) {
                    Text(snippet.resolvedTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .lineLimit(1)
                    if showScopeBadge {
                        snippetScopeBadge
                    }
                    if snippet.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.tertiary))
                    }
                }

                if isCompactLayout {
                    Text(snippet.content.isEmpty ? L10n.tr("snippet.empty") : snippet.content)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? .white.opacity(0.88) : .secondary)
                        .lineLimit(1)

                    compactMetadataRow
                } else {
                    Text(snippet.content.isEmpty ? L10n.tr("snippet.empty") : snippet.content)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        if let groupName = snippet.groupName, !groupName.isEmpty {
                            Text(groupName)
                        }
                        if !snippet.tags.isEmpty {
                            Text(snippet.tags.prefix(2).joined(separator: ", "))
                        }
                        Text(snippet.contentType.label)
                        Text(snippet.usageCount == 0 ? L10n.tr("snippet.unused") : L10n.tr("snippet.usedCount", snippet.usageCount))
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var isCompactLayout: Bool {
        layoutStyle == .compact
    }

    @ViewBuilder
    private var compactMetadataRow: some View {
        if compactFolderName != nil || !compactTagItems.isEmpty {
            HStack(spacing: 6) {
                if let compactFolderName {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9, weight: .medium))
                        Text(compactFolderName)
                            .lineLimit(1)
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(Color(red: 0.37, green: 0.44, blue: 0.55)))
                }

                if compactFolderName != nil, !compactTagItems.isEmpty {
                    Circle()
                        .fill(isSelected ? Color.white.opacity(0.22) : Color.primary.opacity(0.12))
                        .frame(width: 3, height: 3)
                }

                if !compactTagItems.isEmpty {
                    tagCapsules
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var compactFolderName: String? {
        guard let groupName = snippet.groupName?.trimmingCharacters(in: .whitespacesAndNewlines), !groupName.isEmpty else {
            return nil
        }
        return groupName
    }

    private var compactTagItems: [String] {
        Array(snippet.tags.prefix(3))
    }

    private var tagCapsules: some View {
        HStack(spacing: 4) {
            ForEach(compactTagItems, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tagForegroundStyle)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(tagBackgroundStyle, in: Capsule())
            }

            if snippet.tags.count > compactTagItems.count {
                Text("+\(snippet.tags.count - compactTagItems.count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.65)) : AnyShapeStyle(.tertiary))
            }
        }
    }

    private var tagForegroundStyle: AnyShapeStyle {
        isSelected
            ? AnyShapeStyle(.white.opacity(0.82))
            : AnyShapeStyle(Color(red: 0.35, green: 0.43, blue: 0.48))
    }

    private var tagBackgroundStyle: AnyShapeStyle {
        isSelected
            ? AnyShapeStyle(Color.white.opacity(0.14))
            : AnyShapeStyle(Color(red: 0.87, green: 0.91, blue: 0.93))
    }

    private var snippetScopeBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 8, weight: .semibold))
            Text(L10n.tr("snippet.badge"))
                .font(.system(size: 8, weight: .bold, design: .rounded))
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.95)) : AnyShapeStyle(Color.accentColor))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            isSelected ? Color.white.opacity(0.16) : Color.accentColor.opacity(0.12),
            in: Capsule()
        )
    }
}

struct QuickSnippetRow: View {
    let snippet: SnippetItem
    let isSelected: Bool
    var showSnippetScopeBadge: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            SnippetRow(
                snippet: snippet,
                isSelected: isSelected,
                showScopeBadge: showSnippetScopeBadge,
                layoutStyle: .compact
            )
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            isSelected ? Color.primary.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .padding(.vertical, 1)
    }
}

struct SnippetPreviewPane: View {
    let snippet: SnippetItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(snippet.resolvedTitle)
                        .font(.system(size: 18, weight: .semibold))
                    HStack(spacing: 8) {
                        Label(snippet.contentType.label, systemImage: snippet.contentType.icon)
                        if let groupName = snippet.groupName, !groupName.isEmpty {
                            Label(groupName, systemImage: "folder")
                        }
                        if !snippet.tags.isEmpty {
                            Label(snippet.tags.joined(separator: ", "), systemImage: "tag")
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                }

                Divider()

                Text(snippet.content.isEmpty ? L10n.tr("snippet.empty") : snippet.content)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
