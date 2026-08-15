import AppKit

/// A borderless, fully transparent window on the screen under the pointer.
/// `CGShieldingWindowLevel` puts it above the menu bar and the Dock, matching
/// the always-on-top layered window of the Windows build.
final class OverlayWindow: NSWindow {
    private let overlay: OverlayView

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(targets: [URL], options: RunOptions, onFinish: @escaping ([URL: Error]) -> Void) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        overlay = OverlayView(
            frame: CGRect(origin: .zero, size: frame.size),
            targets: targets,
            options: options,
            backingScale: screen?.backingScaleFactor ?? 2,
            onFinish: onFinish
        )
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        contentView = overlay
        makeFirstResponder(overlay)
    }

    func present() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        overlay.start()
    }
}
