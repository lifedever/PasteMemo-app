import AppKit
import AVFoundation

@MainActor
enum SoundManager {
    enum SoundSource: Equatable {
        case system(String)
        case custom(String)

        var displayName: String {
            switch self {
            case .system(let name): return name
            case .custom(let name): return name
            }
        }

        var storageKey: String {
            switch self {
            case .system(let name): return "system:\(name)"
            case .custom(let name): return "custom:\(name)"
            }
        }

        static func from(storageKey: String) -> SoundSource {
            if storageKey.hasPrefix("custom:") {
                let name = String(storageKey.dropFirst("custom:".count))
                return .custom(name)
            }
            if storageKey.hasPrefix("system:") {
                let name = String(storageKey.dropFirst("system:".count))
                return .system(name)
            }
            return .system(storageKey)
        }
    }

    static let SYSTEM_SOUNDS: [SoundSource] = [
        .system("Tink"), .system("Pop"), .system("Bottle"),
        .system("Glass"), .system("Ping"), .system("Purr"),
        .system("Blow"), .system("Frog"), .system("Funk"),
        .system("Hero"), .system("Morse"), .system("Submarine"),
        .system("Basso"), .system("Sosumi"),
    ]

    static let CUSTOM_SOUNDS: [SoundSource] = [
        .custom("sound1"), .custom("sound2"), .custom("sound3"),
    ]

    static let ALL_SOUNDS: [SoundSource] = CUSTOM_SOUNDS + SYSTEM_SOUNDS

    private static let ENABLED_KEY = "soundEnabled"
    private static let COPY_SOUND_KEY = "copySoundName"
    private static let PASTE_SOUND_KEY = "pasteSoundName"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: ENABLED_KEY) as? Bool ?? false
    }

    static var copySoundSource: SoundSource {
        let raw = UserDefaults.standard.string(forKey: COPY_SOUND_KEY) ?? "custom:sound2"
        return SoundSource.from(storageKey: raw)
    }

    static var pasteSoundSource: SoundSource {
        let raw = UserDefaults.standard.string(forKey: PASTE_SOUND_KEY) ?? "custom:sound1"
        return SoundSource.from(storageKey: raw)
    }

    static func playCopy() {
        play(copySoundSource)
    }

    static func playPaste() {
        play(pasteSoundSource)
    }

    /// System sound names available for the relay-complete chime. Empty string = muted.
    static let relayCompleteSoundOptions: [String] = ["", "Pop", "Tink", "Bottle", "Glass", "Ping"]

    static func playRelayComplete() {
        let name = UserDefaults.standard.string(forKey: "relayCompleteSoundName") ?? "Pop"
        guard !name.isEmpty else { return }
        NSSound(named: name)?.play()
    }

    static func preview(_ source: SoundSource) {
        play(source)
    }

    private static var audioPlayer: AVAudioPlayer?

    private static func play(_ source: SoundSource) {
        guard isEnabled else { return }
        switch source {
        case .system(let name):
            NSSound(named: name)?.play()
        case .custom(let name):
            playCustomSound(name)
        }
    }

    private static func playCustomSound(_ name: String) {
        let fileName = mapCustomFileName(name)
        guard let url = Bundle.module.url(
            forResource: fileName,
            withExtension: "wav",
            subdirectory: "Resources/Sounds"
        ) else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            audioPlayer = player
            player.play()
        } catch {
            // Silent failure for sound playback
        }
    }

    private static func mapCustomFileName(_ name: String) -> String {
        switch name {
        case "sound1": return "copy"
        case "sound2": return "paste"
        case "sound3": return "750608__deadrobotmusic__notification-sound-2"
        default: return name
        }
    }
}
