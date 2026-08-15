import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: OverlayWindow?
    /// Finder can deliver the selection before launch finishes; hold it until
    /// there is somewhere to put it.
    private var pending: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        launched = true

        guard Assets.isAvailable else {
            report(title: "怪兽罢工了", message: "找不到素材目录，请从发布包运行 MonsterDeleter.app。")
            NSApp.terminate(nil)
            return
        }

        let fromCommandLine = CommandLine.arguments
            .dropFirst()
            .filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0) }
        summon(with: pending + fromCommandLine)

        // Nothing to delete: explain the two ways in and leave.
        if window == nil {
            showUsage()
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        summon(with: urls)
    }

    // MARK: - Services

    @objc func summonMonster(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        summon(with: pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? [])
    }

    // MARK: - Helpers

    private func summon(with urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        guard launched else {
            pending.append(contentsOf: existing)
            return
        }
        // One monster at a time.
        guard window == nil else { return }

        let window = OverlayWindow(
            targets: existing,
            options: .fromEnvironment
        ) { [weak self] failures in
            self?.window?.orderOut(nil)
            self?.window = nil
            self?.reportFailures(failures)
            NSApp.terminate(nil)
        }
        self.window = window
        window.present()
    }

    /// The view reports which URLs it could not trash; the wording lives here.
    private func reportFailures(_ failures: [URL: Error]) {
        guard !failures.isEmpty else { return }
        let lines = failures
            .map { "\($0.key.lastPathComponent)：\($0.value.localizedDescription)" }
            .sorted()
        report(title: "有文件没能进废纸篓", message: lines.joined(separator: "\n"))
    }

    private func showUsage() {
        report(
            title: "怪兽大将待命中",
            message: """
            在访达里选中文件或文件夹，然后：

            · 右键 →「服务」→「召唤怪兽大将摧毁」
            · 或把它们拖到本 App 图标上

            怪兽会请你用准星标记目标，确认后把它们踹进废纸篓。
            """,
            style: .informational
        )
    }

    private func report(title: String, message: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }
}
