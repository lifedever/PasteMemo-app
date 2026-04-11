import SwiftUI

struct ClipItemRow: View {
    let item: ClipItem
    let onTap: () -> Void
    var sortMode: HistorySortMode = .lastUsed

    var body: some View {
        if item.isDeleted {
            EmptyView()
        } else {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Type icon
                Image(systemName: item.contentType.icon)
                    .foregroundStyle(iconColor)
                    .frame(width: 20)

                // Content preview
                VStack(alignment: .leading, spacing: 2) {
                    if item.contentType == .image {
                        if let data = item.imageData, let nsImage = NSImage(data: data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            Text("[Image]")
                                .font(.callout)
                        }
                    } else {
                        Text(item.content)
                            .font(.callout)
                            .lineLimit(2)
                    }

                    if let app = item.sourceApp {
                        Text(app)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                // Indicators
                HStack(spacing: 4) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                // Time
                Text(sortMode.date(for: item).relativeString)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.clear)
        )
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        }
    }

    private var iconColor: Color {
        switch item.contentType {
        case .link: return .blue
        case .image: return .purple
        case .file, .document: return .cyan
        case .archive: return .orange
        case .application: return .indigo
        case .phone: return .mint
        case .video: return .red
        case .audio: return .pink
        default: return .primary
        }
    }
}

// MARK: - Helpers

extension Date {
    @MainActor
    var relativeString: String {
        let interval = -timeIntervalSinceNow
        if interval < 60 { return L10n.tr("time.now") }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }
}

extension Color {
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8 else { return nil }
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        if h.count == 6 {
            self.init(
                red: Double((rgb >> 16) & 0xFF) / 255,
                green: Double((rgb >> 8) & 0xFF) / 255,
                blue: Double(rgb & 0xFF) / 255
            )
        } else {
            self.init(
                red: Double((rgb >> 24) & 0xFF) / 255,
                green: Double((rgb >> 16) & 0xFF) / 255,
                blue: Double((rgb >> 8) & 0xFF) / 255,
                opacity: Double(rgb & 0xFF) / 255
            )
        }
    }
}
