import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: OverlayWindow?
    /// Finder can deliver the selection before or after launch finishes; a
    /// pending list covers the early case.
    private var pending: [URL] = []
    private var launched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        launched = true

        guard Assets.isAvailable else {
            report("找不到素材目录，请从发布包运行 MonsterDeleter.app。")
            NSApp.terminate(nil)
            return
        }

        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let fromCommandLine = arguments.map { URL(fileURLWithPath: $0) }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Services

    @objc func summonMonster(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        summon(with: urls)
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

        let window = OverlayWindow.make(targets: existing) { [weak self] failure in
            self?.window?.orderOut(nil)
            self?.window = nil
            if let failure { self?.report("有文件没能移进废纸篓：\n\(failure)") }
            NSApp.terminate(nil)
        }
        self.window = window
        window.present()
    }

    private func showUsage() {
        let alert = NSAlert()
        alert.messageText = "怪兽大将待命中"
        alert.informativeText = """
        在访达里选中文件或文件夹，然后：

        · 右键 →「服务」→「召唤怪兽摧毁」
        · 或把它们拖到本 App 图标上

        怪兽会请你用准星标记目标，确认后把它们踹进废纸篓。
        """
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "怪兽罢工了"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
