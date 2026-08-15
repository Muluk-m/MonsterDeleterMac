import Foundation

/// Locates the bundled artwork and audio.
///
/// The same binary runs from an assembled `.app` and straight out of
/// `swift run`, so both layouts are probed before giving up.
enum Assets {
    static let root: URL = {
        let fileManager = FileManager.default
        if let resources = Bundle.main.resourceURL {
            let candidate = resources.appendingPathComponent("assets", isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        var directory = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("assets", isDirectory: true)
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: "assets", isDirectory: true)
    }()

    static func url(_ components: String...) -> URL {
        components.reduce(root) { $0.appendingPathComponent($1) }
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: root.path)
    }
}
