import SwiftUI
import AVFoundation
import AVKit
import AppKit

struct VideoThumbnailView: View {
    let path: String
    @State private var thumbnail: NSImage?
    @State private var duration: String = ""
    @State private var isPlaying = false

    var body: some View {
        ZStack {
            if isPlaying {
                VideoPlayerView(url: URL(fileURLWithPath: path))
            } else if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .contentShape(Rectangle())
                    .onTapGesture { isPlaying = true }

                overlay
                    .onTapGesture { isPlaying = true }
            } else {
                placeholder
            }
        }
        .task(id: path) {
            isPlaying = false
            await generateThumbnail()
        }
        .onDisappear { isPlaying = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in isPlaying = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in isPlaying = false }
    }

    private var overlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                    if !duration.isEmpty {
                        Text(duration)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "film")
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func generateThumbnail() async {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)

        do {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

            let totalSeconds = try await CMTimeGetSeconds(asset.load(.duration))
            let formatted = formatDuration(totalSeconds)

            await MainActor.run {
                thumbnail = image
                duration = formatted
            }
        } catch {
            // Thumbnail generation failed — placeholder stays
        }
    }

    private func formatDuration(_ seconds: Float64) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// Native AVPlayer wrapper — only created when user clicks play
struct VideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        let player = AVPlayer(url: url)
        playerView.player = player
        playerView.controlsStyle = .inline
        player.play()
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
