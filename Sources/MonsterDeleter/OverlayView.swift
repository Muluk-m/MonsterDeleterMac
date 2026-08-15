import AppKit

private let frameRate: Double = 8

/// Sequence timings copied from the Windows build so the pacing matches.
private enum Timing {
    static let selectFadeIn: Double = 0.8
    static let fadeOut: Double = 0.5
    static let walk: Double = 4.5
    static let point: Double = 0.5
    static let sheet: Double = 15.0 / frameRate  // one full 15-frame pass
    static let fly: Double = 2.0
    static let deleteAtFrame = 5
}

enum Phase {
    case select, fadeOut, walk, point, ask, kick, leo, fly
}

private enum SpriteKey {
    case walk, point, kick, leo, fly, explosion
}

final class OverlayView: NSView {
    private let targets: [URL]
    private let onFinish: (String?) -> Void

    private var phase: Phase = .select
    private var phaseStarted = Date()
    private var targetPosition = CGPoint.zero
    private var pointsLeft = false

    private var background: CGImage?
    private var walk: Sprite?
    private var point: Sprite?
    private var kick: Sprite?
    private var leo: Sprite?
    private var fly: Sprite?
    private var explosion: Sprite?

    private var explosionStarted: Date?
    private var explosionPositions: [CGPoint] = []
    private var deletionStarted = false
    private var failure: String?

    private let audio = Audio()
    private var timer: Timer?
    private let loadQueue = DispatchQueue(label: "com.monsterdeleter.sprites", qos: .userInitiated)

    /// Self-test hook: `MONSTER_AUTOPLAY=x,y` drives the two clicks the user
    /// would make, so the whole sequence can be recorded without a human.
    private let autoplayPoint: CGPoint? = {
        guard let raw = ProcessInfo.processInfo.environment["MONSTER_AUTOPLAY"] else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return CGPoint(x: parts[0], y: parts[1])
    }()

    /// Self-test hook: `MONSTER_SNAPSHOT=<dir>` writes one PNG per checkpoint.
    /// Screen recording needs a TCC grant the app cannot assume, so the view
    /// renders itself instead.
    private let snapshotDirectory: URL? = ProcessInfo.processInfo
        .environment["MONSTER_SNAPSHOT"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
    private var snapshotsTaken: Set<String> = []
    private var tickCount = 0
    private var preloadStarted = false

    init(frame: NSRect, targets: [URL], onFinish: @escaping (String?) -> Void) {
        self.targets = targets
        self.onFinish = onFinish
        super.init(frame: frame)
        targetPosition = CGPoint(x: frame.width / 2, y: frame.height / 2)
        // Pre-composited at screen size: rescaling the 1375×768 source every
        // frame stalled the first ~1.5s of the fade-in.
        background = Self.makeBackground(size: frame.size)
    }

    private static func makeBackground(size: CGSize, scale: CGFloat = 2) -> CGImage? {
        guard let source = Sprite.loadImage(Assets.url("选择界面", "选择界面.png")) else { return nil }
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        // Cover: fill the screen, cropping the overflow evenly.
        let cover = max(
            CGFloat(pixelWidth) / CGFloat(source.width),
            CGFloat(pixelHeight) / CGFloat(source.height)
        )
        let width = CGFloat(source.width) * cover
        let height = CGFloat(source.height) * cover
        context.interpolationQuality = .high
        context.draw(
            source,
            in: CGRect(
                x: (CGFloat(pixelWidth) - width) / 2,
                y: (CGFloat(pixelHeight) - height) / 2,
                width: width,
                height: height
            )
        )
        return context.makeImage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Lifecycle

    func start() {
        phaseStarted = Date()
        display()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        audio.stopAll()
        onFinish(failure)
    }

    /// Started once the user has marked a target: decoding six sheets while
    /// the selection screen is still fading in competes with the main thread.
    /// The first sheet is only needed 0.5s later, after the fade-out.
    private func preload() {
        guard !preloadStarted else { return }
        preloadStarted = true
        let specs: [(file: String, height: CGFloat, key: SpriteKey)] = [
            ("走路动效_spritesheet_transparent.png", 250, .walk),
            ("指着文件_spritesheet_transparent.png", 250, .point),
            ("踹文件动效_spritesheet_transparent.png", 250, .kick),
            ("雷欧登场_spritesheet_transparent.png", 250, .leo),
            ("出场飞行动效_spritesheet_transparent.png", 250, .fly),
            // Loaded last: the source sheet is 7200×5760 and dominates decode time.
            ("爆炸_spritesheet_transparent.png", 150, .explosion),
        ]
        loadQueue.async { [weak self] in
            for spec in specs {
                let sprite = Sprite.load(Assets.url(spec.file), height: spec.height)
                DispatchQueue.main.async { self?.store(sprite, for: spec.key) }
            }
        }
    }

    private func store(_ sprite: Sprite?, for key: SpriteKey) {
        guard let sprite else { return }
        switch key {
        case .walk: walk = walk ?? sprite
        case .point: point = point ?? sprite
        case .kick: kick = kick ?? sprite
        case .leo: leo = leo ?? sprite
        case .fly: fly = fly ?? sprite
        case .explosion: explosion = explosion ?? sprite
        }
    }

    // MARK: - Phase machine

    private var elapsed: Double { Date().timeIntervalSince(phaseStarted) }
    private var frameIndex: Int { max(0, Int(elapsed * frameRate)) }

    private func enter(_ next: Phase) {
        phase = next
        phaseStarted = Date()
        window?.invalidateCursorRects(for: self)
    }

    private func tick() {
        if tickCount == 0 {
            if snapshotDirectory != nil {
                FileHandle.standardError.write(
                    Data("[monster] first tick at \(String(format: "%.3f", elapsed))s\n".utf8)
                )
            }
            // Putting a full-screen transparent window on screen costs well
            // over a second on a cold launch, and nothing repaints until it
            // lands. Restart the clock here so the fade-in plays from the
            // beginning instead of snapping to its midpoint.
            phaseStarted = Date()
        }
        tickCount += 1

        if let autoplayPoint {
            if phase == .select, elapsed >= 1.5 {
                handleClick(at: autoplayPoint)
            } else if phase == .ask, elapsed >= 1.0 {
                let button = choiceRects()[0]
                handleClick(at: CGPoint(x: button.midX, y: button.midY))
            }
        }

        switch phase {
        case .fadeOut where elapsed >= Timing.fadeOut:
            audio.playLoop("bgm")
            enter(.walk)
        case .walk where elapsed >= Timing.walk:
            // The question SFX starts with the pointing animation and carries
            // into the bubble; it is not restarted when the bubble appears.
            audio.play("talk")
            enter(.point)
        case .point where elapsed >= Timing.point:
            enter(.ask)
        case .kick:
            if frameIndex >= Timing.deleteAtFrame, !deletionStarted { triggerDelete() }
            if elapsed >= Timing.sheet { enter(.leo) }
        case .leo where elapsed >= Timing.sheet:
            enter(.fly)
        case .fly where elapsed >= Timing.fly:
            finish()
            return
        default:
            break
        }
        needsDisplay = true
        captureSnapshotIfNeeded()
    }

    private static let snapshotCheckpoints: [(phase: Phase, at: Double, name: String)] = [
        (.select, 0.2, "00-select-early"),
        (.select, 1.0, "01-select"),
        (.fadeOut, 0.25, "02-fadeout"),
        (.walk, 1.0, "03-walk-early"),
        (.walk, 3.5, "04-walk-late"),
        (.point, 0.3, "05-point"),
        (.ask, 0.5, "06-ask"),
        (.kick, 0.8, "07-kick-boom"),
        (.leo, 0.8, "08-leo"),
        (.fly, 0.6, "09-fly"),
    ]

    private func captureSnapshotIfNeeded() {
        guard let directory = snapshotDirectory else { return }
        for checkpoint in Self.snapshotCheckpoints
        where checkpoint.phase == phase
            && elapsed >= checkpoint.at
            && !snapshotsTaken.contains(checkpoint.name) {
            snapshotsTaken.insert(checkpoint.name)
            writeSnapshot(named: checkpoint.name, to: directory)
        }
    }

    private func writeSnapshot(named name: String, to directory: URL) {
        // `cacheDisplay` hands back a rep without alpha, which turns every
        // transparent pixel white. Render into an explicit RGBA buffer instead.
        let scale = window?.backingScaleFactor ?? 2
        guard let layer = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale),
            pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        layer.size = bounds.size

        NSGraphicsContext.saveGraphicsState()
        if let base = NSGraphicsContext(bitmapImageRep: layer) {
            // A flipped view gets this transform from AppKit during a real
            // draw; reproduce it so the same drawing code lands right-side up.
            // The context must also *report* itself flipped, or text drawing
            // compensates a second time and comes out mirrored.
            let flipped = NSGraphicsContext(cgContext: base.cgContext, flipped: true)
            NSGraphicsContext.current = flipped
            flipped.cgContext.translateBy(x: 0, y: bounds.height)
            flipped.cgContext.scaleBy(x: 1, y: -1)
            draw(bounds)
        }
        NSGraphicsContext.restoreGraphicsState()

        // Grey stand-in for the desktop, so transparency stays readable.
        let composite = NSImage(size: bounds.size)
        composite.lockFocus()
        NSColor(white: 0.25, alpha: 1).setFill()
        bounds.fill()
        layer.draw(in: bounds)
        composite.unlockFocus()

        guard let tiff = composite.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) {
        handleClick(at: convert(event.locationInWindow, from: nil))
    }

    private func handleClick(at location: CGPoint) {
        switch phase {
        case .select:
            targetPosition = location
            pointsLeft = location.x < bounds.width / 2
            preload()
            enter(.fadeOut)
        case .ask:
            // Both replies are agreement — that is the original joke.
            if choiceRects().contains(where: { $0.contains(location) }) {
                deletionStarted = false
                explosionStarted = nil
                enter(.kick)
            }
        default:
            break
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish() } // esc
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: phase == .select ? Crosshair.cursor : .arrow)
    }

    // MARK: - Deletion

    private func triggerDelete() {
        deletionStarted = true
        explosionStarted = Date()
        explosionPositions = explosionPositionsForDelete()
        audio.play("boom")

        var failures: [String] = []
        for url in targets {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { failure = failures.joined(separator: "\n") }
    }

    /// Finder hands over a selection without icon coordinates, so several
    /// explosions are fanned around the point the user marked.
    private func explosionPositionsForDelete() -> [CGPoint] {
        let count = max(targets.count, 1)
        if count == 1 { return [targetPosition] }
        return (0..<count).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(count)
            let radius = CGFloat(42 + (index % 3) * 18)
            return CGPoint(
                x: targetPosition.x + cos(angle) * radius,
                y: targetPosition.y + sin(angle) * radius
            )
        }
    }

    // MARK: - Layout

    private func monsterPosition(_ sprite: Sprite) -> CGPoint {
        let x = pointsLeft ? targetPosition.x + 30 : targetPosition.x - sprite.width - 30
        return CGPoint(x: x, y: targetPosition.y - sprite.height / 2 + 50)
    }

    private func choiceRects() -> [CGRect] {
        let anchor: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)
        if let sprite = point {
            let position = monsterPosition(sprite)
            anchor = (position.x, position.y, sprite.width, sprite.height)
        } else {
            anchor = (targetPosition.x, targetPosition.y, 250, 250)
        }

        let groupWidth: CGFloat = 297
        let margin: CGFloat = 12
        let x = clamp(
            anchor.x + anchor.width / 2 - groupWidth / 2,
            margin,
            bounds.width - groupWidth - margin
        )
        let below = anchor.y + anchor.height + 68 <= bounds.height - margin
        let y = below ? anchor.y + anchor.height + 16 : max(anchor.y - 68, margin)
        return [
            CGRect(x: x, y: y, width: 92, height: 52),
            CGRect(x: x + 107, y: y, width: 190, height: 52),
        ]
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard upper > lower else { return lower }
        return min(max(value, lower), upper)
    }

    // MARK: - Rendering

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        switch phase {
        case .select:
            drawSelection(context, opacity: min(elapsed / Timing.selectFadeIn, 1) * 0.35)
        case .fadeOut:
            drawSelection(context, opacity: max(1 - elapsed / Timing.fadeOut, 0) * 0.35)
        case .walk:
            drawWalk(context)
        case .point:
            drawPoint(context)
        case .ask:
            drawAsk(context)
        case .kick:
            if let sprite = kick {
                drawSprite(context, sprite, frame: min(frameIndex, 14), at: monsterPosition(sprite))
            }
            drawExplosion(context)
        case .leo:
            if let sprite = leo {
                drawSprite(context, sprite, frame: min(frameIndex, 14), at: monsterPosition(sprite))
            }
        case .fly:
            drawFly(context)
        }
    }

    private func drawSelection(_ context: CGContext, opacity: Double) {
        if let background {
            draw(context, image: background, in: bounds, alpha: CGFloat(opacity))
        } else {
            context.setFillColor(NSColor(white: 0, alpha: CGFloat(opacity) * 0.63).cgColor)
            context.fill(bounds)
        }

        let alpha = CGFloat(min(opacity / 0.35, 1))
        drawText(
            "请选择你要摧毁的文件",
            in: CGRect(x: bounds.width / 2 - 300, y: bounds.height / 2 - 28, width: 600, height: 56),
            size: 30,
            color: NSColor(white: 1, alpha: alpha)
        )
    }

    private func drawWalk(_ context: CGContext) {
        guard let sprite = walk else { return }
        let progress = min(elapsed / Timing.walk, 1)
        let end = monsterPosition(sprite)
        let startX = pointsLeft ? bounds.width : -sprite.width
        let eased = 1 - (1 - progress) * (1 - progress)
        let x = startX + (end.x - startX) * CGFloat(eased)
        drawSprite(context, sprite, frame: frameIndex, at: CGPoint(x: x, y: end.y))
    }

    private func drawPoint(_ context: CGContext) {
        guard let sprite = point else { return }
        drawSprite(context, sprite, frame: 11 + min(frameIndex, 3), at: monsterPosition(sprite))
    }

    private func drawAsk(_ context: CGContext) {
        guard let sprite = point else { return }
        let position = monsterPosition(sprite)
        drawSprite(context, sprite, frame: 14, at: position)

        let message = targets.count > 1 ? "喂，是这些吗？" : "喂，是这个吗？"
        let second = targets.count > 1 ? "嘤嘤嘤就是这些" : "嘤嘤嘤就是这个"
        drawBubble(
            context,
            monsterSize: CGSize(width: sprite.width, height: sprite.height),
            at: position,
            message: message,
            firstChoice: "是的",
            secondChoice: second
        )
    }

    private func drawFly(_ context: CGContext) {
        guard let sprite = fly else { return }
        let progress = CGFloat(min(elapsed / Timing.fly, 1))
        let start = monsterPosition(sprite)
        let endX = pointsLeft ? -sprite.width - 200 : bounds.width + 200
        let x = start.x + (endX - start.x) * progress * progress
        drawSprite(context, sprite, frame: frameIndex, at: CGPoint(x: x, y: start.y))
    }

    private func drawExplosion(_ context: CGContext) {
        guard let started = explosionStarted, let sprite = explosion else { return }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed <= Timing.sheet else { return }
        let image = sprite.frame(Int(elapsed * frameRate))
        for position in explosionPositions {
            draw(
                context,
                image: image,
                in: CGRect(
                    x: position.x - sprite.width / 2,
                    y: position.y - sprite.height / 2 - 40,
                    width: sprite.width,
                    height: sprite.height
                ),
                alpha: 1
            )
        }
    }

    private func drawBubble(
        _ context: CGContext,
        monsterSize: CGSize,
        at position: CGPoint,
        message: String,
        firstChoice: String,
        secondChoice: String
    ) {
        let bubbleWidth: CGFloat = 220
        let bubbleHeight: CGFloat = message.contains("\n") ? 80 : 64
        let margin: CGFloat = 28
        let tail: CGFloat = 15

        let rawX = pointsLeft
            ? position.x + monsterSize.width + 18
            : position.x - bubbleWidth - 18
        let x = clamp(rawX, margin, bounds.width - bubbleWidth - margin)
        let sideY = position.y + monsterSize.height * 0.3 - bubbleHeight / 2
        let below = sideY < margin
        let y = clamp(
            below ? position.y + monsterSize.height + 20 : sideY,
            margin,
            bounds.height - bubbleHeight - margin
        )
        let bubble = CGRect(x: x, y: y, width: bubbleWidth, height: bubbleHeight)

        let targetY = clamp(position.y + monsterSize.height / 2, y + tail, y + bubbleHeight - tail)
        let corners: (CGPoint, CGPoint, CGPoint)
        if below {
            corners = (
                CGPoint(x: x + bubbleWidth / 2 - tail, y: y),
                CGPoint(x: x + bubbleWidth / 2 + tail, y: y),
                CGPoint(x: x + bubbleWidth / 2, y: y - tail)
            )
        } else if pointsLeft {
            corners = (
                CGPoint(x: x, y: targetY - tail),
                CGPoint(x: x, y: targetY + tail),
                CGPoint(x: x - tail, y: targetY)
            )
        } else {
            corners = (
                CGPoint(x: x + bubbleWidth, y: targetY - tail),
                CGPoint(x: x + bubbleWidth, y: targetY + tail),
                CGPoint(x: x + bubbleWidth + tail, y: targetY)
            )
        }

        drawTriangle(
            context,
            corners.0.offsetBy(dy: 7),
            corners.1.offsetBy(dy: 7),
            corners.2.offsetBy(dy: 7),
            color: NSColor(white: 0, alpha: 28.0 / 255.0)
        )
        drawTriangle(context, corners.0, corners.1, corners.2, color: NSColor(white: 1, alpha: 240.0 / 255.0))
        drawCard(context, rect: bubble, radius: 20, shadowOffset: 8, shadowBlur: 14)
        drawText(message, in: bubble, size: 20, color: NSColor(white: 28.0 / 255.0, alpha: 1))

        let choices = choiceRects()
        for rect in choices {
            drawCard(context, rect: rect, radius: 18, shadowOffset: 5, shadowBlur: 10)
        }
        drawText(firstChoice, in: choices[0], size: 16, color: NSColor(white: 28.0 / 255.0, alpha: 1))
        drawText(secondChoice, in: choices[1], size: 16, color: NSColor(white: 28.0 / 255.0, alpha: 1))
    }

    // MARK: - Primitives

    private func drawSprite(_ context: CGContext, _ sprite: Sprite, frame: Int, at position: CGPoint) {
        draw(
            context,
            image: sprite.frame(frame),
            in: CGRect(x: position.x, y: position.y, width: sprite.width, height: sprite.height),
            alpha: 1,
            mirrored: pointsLeft
        )
    }

    /// The view is flipped, so every image is drawn through an explicit
    /// vertical flip; mirroring folds into the same transform.
    private func draw(
        _ context: CGContext,
        image: CGImage,
        in rect: CGRect,
        alpha: CGFloat,
        mirrored: Bool = false
    ) {
        guard alpha > 0 else { return }
        context.saveGState()
        context.setAlpha(alpha)
        context.interpolationQuality = .high
        context.translateBy(x: mirrored ? rect.maxX : rect.minX, y: rect.maxY)
        context.scaleBy(x: mirrored ? -1 : 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    private func drawCard(
        _ context: CGContext,
        rect: CGRect,
        radius: CGFloat,
        shadowOffset: CGFloat,
        shadowBlur: CGFloat
    ) {
        context.saveGState()
        // Negative dy because the flipped CTM points y upward on screen.
        context.setShadow(
            offset: CGSize(width: 0, height: -shadowOffset),
            blur: shadowBlur,
            color: NSColor(white: 0, alpha: 0.11).cgColor
        )
        context.setFillColor(NSColor(white: 1, alpha: 240.0 / 255.0).cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    private func drawTriangle(_ context: CGContext, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint, color: NSColor) {
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.move(to: a)
        context.addLine(to: b)
        context.addLine(to: c)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    private func drawText(_ text: String, in rect: CGRect, size: CGFloat, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .medium),
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
        )
        let measured = attributed.boundingRect(
            with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        )
        attributed.draw(
            with: CGRect(
                x: rect.minX,
                y: rect.minY + (rect.height - measured.height) / 2,
                width: rect.width,
                height: measured.height
            ),
            options: [.usesLineFragmentOrigin]
        )
    }
}

private extension CGPoint {
    func offsetBy(dy: CGFloat) -> CGPoint { CGPoint(x: x, y: y + dy) }
}
