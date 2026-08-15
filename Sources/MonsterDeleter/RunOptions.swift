import CoreGraphics
import Foundation

/// Self-test switches, read once from the environment instead of being probed
/// at whatever layer happens to need them.
struct RunOptions {
    var autoplayPoint: CGPoint?
    var snapshotDirectory: URL?
    var audioEnabled = true
    /// Off lets the whole sequence be exercised without trashing real files.
    var deletionEnabled = true

    static let fromEnvironment: RunOptions = {
        let environment = ProcessInfo.processInfo.environment
        var options = RunOptions()
        if let raw = environment["MONSTER_AUTOPLAY"] {
            let parts = raw
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 {
                options.autoplayPoint = CGPoint(x: parts[0], y: parts[1])
            }
        }
        options.snapshotDirectory = environment["MONSTER_SNAPSHOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        options.audioEnabled = environment["MONSTER_NO_AUDIO"] == nil
        options.deletionEnabled = environment["MONSTER_NO_DELETE"] == nil
        return options
    }()
}
