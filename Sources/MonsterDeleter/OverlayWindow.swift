import AppKit

/// A borderless, fully transparent window on the screen under the pointer.
/// `CGShieldingWindowLevel` puts it above the menu bar and the Dock, matching
/// the always-on-top layered window of the Windows build.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    static func make(targets: [URL], onFinish: @escaping (String?) -> Void) -> OverlayWindow {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let window = OverlayWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true

        let view = OverlayView(
            frame: CGRect(origin: .zero, size: frame.size),
            targets: targets,
            onFinish: onFinish
        )
        window.contentView = view
        window.makeFirstResponder(view)
        return window
    }

    func present() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        (contentView as? OverlayView)?.start()
    }
}
