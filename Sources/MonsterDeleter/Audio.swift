import AVFoundation

/// The three cues from the original build. Volumes mirror the Windows MCI
/// levels (500 / 1000 / 300 per mille).
final class Audio {
    private var players: [String: AVAudioPlayer] = [:]

    init() {
        if ProcessInfo.processInfo.environment["MONSTER_NO_AUDIO"] != nil { return }
        let files: [(name: String, path: [String], volume: Float)] = [
            ("bgm", ["音频", "bgm(1).mp3"], 0.5),
            ("talk", ["音频", "monster-talk.wav"], 1.0),
            ("boom", ["音频", "monster-boom.wav"], 0.3),
        ]
        for file in files {
            let url = file.path.reduce(Assets.root) { $0.appendingPathComponent($1) }
            guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.volume = file.volume
            player.prepareToPlay()
            players[file.name] = player
        }
    }

    func playLoop(_ name: String) {
        guard let player = players[name] else { return }
        player.numberOfLoops = -1
        player.currentTime = 0
        player.play()
    }

    func play(_ name: String) {
        guard let player = players[name] else { return }
        player.stop()
        player.currentTime = 0
        player.play()
    }

    func stopAll() {
        for player in players.values { player.stop() }
    }
}
