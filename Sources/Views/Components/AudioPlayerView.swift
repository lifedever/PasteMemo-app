import SwiftUI
import AVFoundation

struct AudioPlayerView: View {
    let path: String
    var iconSize: CGFloat = 64
    var nameFont: Font = .system(size: 15, weight: .medium)
    var onOpenInFinder: (() -> Void)?

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: TimeInterval = 0
    @State private var timer: Timer?
    @State private var isButtonHovered = false

    private var finderAppIcon: NSImage {
        NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
    }

    private var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)

            Text(fileName)
                .font(nameFont)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)

            playbackControls

            Button {
                onOpenInFinder?()
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
            } label: {
                HStack(spacing: 4) {
                    Image(nsImage: finderAppIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                    Text(L10n.tr("detail.openInFinder"))
                        .font(.system(size: 12))
                }
                .foregroundStyle(isButtonHovered ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .onHover { isButtonHovered = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear(perform: preparePlayer)
        .onDisappear(perform: stopPlayback)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in stopPlayback() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stopPlayback() }
    }

    private var playbackControls: some View {
        VStack(spacing: 6) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * progress, height: 4)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let ratio = min(max(value.location.x / geo.size.width, 0), 1)
                            seek(to: ratio)
                        }
                )
            }
            .frame(height: 4)
            .frame(maxWidth: 220)

            HStack(spacing: 16) {
                Text(formatTime(currentTime))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                Text(formatTime(duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
    }

    private var currentTime: TimeInterval {
        player?.currentTime ?? 0
    }

    private func preparePlayer() {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.prepareToPlay()
            duration = audioPlayer.duration
            player = audioPlayer
        } catch {
            // File cannot be played
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            stopTimer()
        } else {
            if player.currentTime >= player.duration {
                player.currentTime = 0
            }
            player.play()
            startTimer()
        }
        isPlaying = player.isPlaying
    }

    private func seek(to ratio: Double) {
        guard let player else { return }
        player.currentTime = duration * ratio
        progress = ratio
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [self] _ in
            MainActor.assumeIsolated {
                guard let player else { return }
                if player.isPlaying {
                    progress = duration > 0 ? player.currentTime / duration : 0
                } else {
                    isPlaying = false
                    stopTimer()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func stopPlayback() {
        player?.stop()
        stopTimer()
        isPlaying = false
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
