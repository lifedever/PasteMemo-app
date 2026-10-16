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
            case .custom(let name):
                // 存储键（sound1/2/3）不能动——已写进用户 UserDefaults，这里只映射显示名
                switch name {
                case "sound1": return "Drop"
                case "sound2": return "Tap"
                case "sound3": return "Chime"
                default: return name
                }
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
        // 成对设计:复制音上扬/明亮,粘贴音下落/低沉
        .custom("Bubble"), .custom("Bloop"),       // 水泡:上浮 / 下落
        .custom("Snap"), .custom("SnapDown"),      // 快门:咔嚓 / 落定
        .custom("ChirpUp"), .custom("ChirpDown"),  // 双音符:上行 / 下行
        .custom("WoodHigh"), .custom("WoodLow"),   // 木琴:高敲 / 低锤
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
        guard isEnabled else { return }
        play(copySoundSource)
    }

    static func playPaste() {
        guard isEnabled else { return }
        play(pasteSoundSource)
    }

    /// System sound names available for the relay-complete chime. Empty string = muted.
    static let relayCompleteSoundOptions: [String] = [
        "",           // mute
        "Basso",
        "Blow",
        "Bottle",
        "Frog",
        "Funk",
        "Glass",
        "Hero",
        "Morse",
        "Ping",
        "Pop",
        "Purr",
        "Sosumi",
        "Submarine",
        "Tink",
    ]

    static func playRelayComplete() {
        let name = UserDefaults.standard.string(forKey: "relayCompleteSoundName") ?? "Pop"
        guard !name.isEmpty else { return }
        NSSound(named: name)?.play()
    }

    /// Plays a named system sound immediately — used by the settings picker so the user
    /// hears what they just selected. Empty name is a no-op (mute selection).
    static func previewRelayCompleteSound(_ name: String) {
        guard !name.isEmpty else { return }
        NSSound(named: name)?.play()
    }

    static func preview(_ source: SoundSource) {
        play(source)
    }

    /// The "play sound" rule action. Plays even with copy / paste sounds turned
    /// off: the user put this sound into the rule on purpose.
    static func play(storageKey: String) {
        guard !storageKey.isEmpty else { return }
        play(SoundSource.from(storageKey: storageKey))
    }

    private static var audioPlayer: AVAudioPlayer?

    private static func play(_ source: SoundSource) {
        switch source {
        case .system(let name):
            NSSound(named: name)?.play()
        case .custom(let name):
            playCustomSound(name)
        }
    }

    private static func playCustomSound(_ name: String) {
        let fileName = mapCustomFileName(name)
        guard let url = Bundle.pasteMemoResources.url(
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
