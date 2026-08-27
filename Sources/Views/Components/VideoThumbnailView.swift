import SwiftUI
import AVFoundation
import AVKit
import AppKit

struct VideoThumbnailView: View {
    let path: String
    /// Stored thumbnail, when the clip has one. Lets a clip whose source file was since
    /// deleted still show its frame instead of degrading to the gray placeholder.
    var storedThumbnail: Data? = nil
    @State private var thumbnail: NSImage?
    @State private var duration: String = ""
    @State private var isPlaying = false
    /// nil until the probe returns — rendering an "unavailable" badge before then would
    /// flash a false warning on every perfectly fine video.
    @State private var availability: FileAvailability?

    var body: some View {
        ZStack {
            if isPlaying {
                VideoPlayerView(url: URL(fileURLWithPath: path))
            } else if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .contentShape(Rectangle())
                    .onTapGesture { play() }

                overlay
                    .onTapGesture { play() }
            } else {
                placeholder
            }
        }
        .task(id: taskID) {
            isPlaying = false
            await generateThumbnail()
        }
        .onDisappear { isPlaying = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in isPlaying = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in isPlaying = false }
    }

    /// Re-runs when the stored thumbnail arrives (background backfill writes it in).
    private var taskID: String { "\(path)_\(storedThumbnail?.count ?? 0)" }

    /// Treat "not probed yet" as playable — AVPlayer simply fails if the file turns out to
    /// be gone, which beats swallowing a legitimate click during the probe.
    private var isUnavailable: Bool { availability.map { !$0.isAvailable } ?? false }

    private func play() {
        guard !isUnavailable else { return }
        isPlaying = true
    }

    private var overlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    // A stored thumbnail outlives its source file, so the badge has to
                    // state which one you're looking at — otherwise the play affordance
                    // lies about a video that can no longer be opened.
                    if isUnavailable {
                        Image(systemName: unavailableIcon)
                            .font(.system(size: 10))
                        Text(unavailableLabel)
                            .font(.system(size: 11, weight: .medium))
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                        if !duration.isEmpty {
                            Text(duration)
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                        }
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
            Image(systemName: isUnavailable ? unavailableIcon : "film")
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if isUnavailable {
                Text(unavailableLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailableIcon: String {
        availability == .denied ? "lock.fill" : "questionmark.folder"
    }

    private var unavailableLabel: String {
        L10n.tr(availability == .denied ? "file.unavailable.denied" : "file.unavailable.missing")
    }

    private func generateThumbnail() async {
        // Stored thumbnail first: it's the only thing that still renders once the source
        // app has purged its temp file, which is where most video clips come from.
        if let storedThumbnail, let image = NSImage(data: storedThumbnail) {
            thumbnail = image
        }

        // Off the main thread: open(2) can stall on a network volume or an unmounted disk.
        let state = await Task.detached(priority: .utility) { [path] in
            FileAvailability.check(path)
        }.value
        guard !Task.isCancelled else { return }
        availability = state
        guard state.isAvailable else { return }

        if let cached = ImageCache.shared.videoThumbnail(forPath: path) {
            thumbnail = cached
            duration = ImageCache.shared.cachedVideoDuration(forPath: path) ?? ""
            return
        }

        let task = ImageCache.shared.videoThumbnailTask(forPath: path)
        _ = await task.value

        guard !Task.isCancelled else { return }
        // Keep the stored frame if live generation came up empty.
        if let generated = ImageCache.shared.videoThumbnail(forPath: path) {
            thumbnail = generated
        }
        duration = ImageCache.shared.cachedVideoDuration(forPath: path) ?? ""
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
