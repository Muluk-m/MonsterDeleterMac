import AVFoundation

/// The three cues from the original build. Volumes mirror the Windows MCI
/// levels (500 / 1000 / 300 per mille).
///
/// Construct this off the main thread: the first `prepareToPlay` brings up
/// CoreAudio and measured ~740ms on a cold launch.
final class Audio {
    private var players: [String: AVAudioPlayer] = [:]

    init() {
        let files: [(name: String, file: String, volume: Float)] = [
            ("bgm", "bgm(1).mp3", 0.5),
            ("talk", "monster-talk.wav", 1.0),
            ("boom", "monster-boom.wav", 0.3),
        ]
        for file in files {
            guard let player = try? AVAudioPlayer(contentsOf: Assets.url("音频", file.file)) else {
                continue
            }
            player.volume = file.volume
            player.prepareToPlay()
            players[file.name] = player
        }
    }

    func play(_ name: String, loop: Bool = false) {
        guard let player = players[name] else { return }
        player.stop()
        player.numberOfLoops = loop ? -1 : 0
        player.currentTime = 0
        player.play()
    }

    func stopAll() {
        for player in players.values { player.stop() }
    }
}
