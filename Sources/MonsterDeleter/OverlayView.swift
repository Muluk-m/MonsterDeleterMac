import AppKit

private let frameRate: Double = 8

/// Sequence timings copied from the Windows build so the pacing matches.
private enum Timing {
    static let selectFadeIn: Double = 0.8
    static let fadeOut: Double = 0.5
    static let walk: Double = 4.5
    static let point: Double = 0.5
    /// One full pass over a 15-frame sheet.
    static let sheet = Double(Sprite.frameCount) / frameRate
    static let fly: Double = 2.0
    static let deleteAtFrame = 5
    /// How long the walk waits for its sheet before giving up and playing on.
    static let assetWait: Double = 3.0
}

/// The dimming the selection backdrop is drawn at. Baked into the
/// pre-composited image so the steady state needs no global alpha.
private let selectionOpacity: Double = 0.35

private enum Layout {
    static let monsterHeight: CGFloat = 250
    static let explosionHeight: CGFloat = 150

    static let bubbleWidth: CGFloat = 220
    static let bubbleMargin: CGFloat = 28
    static let bubbleTail: CGFloat = 15

    static let firstChoiceWidth: CGFloat = 92
    static let secondChoiceWidth: CGFloat = 190
    static let choiceGap: CGFloat = 15
    static let choiceHeight: CGFloat = 52
    static let choiceMargin: CGFloat = 12
    static var choiceGroupWidth: CGFloat { firstChoiceWidth + choiceGap + secondChoiceWidth }
}

enum Phase {
    case select, fadeOut, walk, point, ask, kick, leo, fly
}

enum SpriteKey {
    case walk, point, kick, leo, fly, explosion
}

final class OverlayView: NSView {
    private let targets: [URL]
    private let options: RunOptions
    private let trash: ([URL]) -> [URL: Error]
    private let onFinish: ([URL: Error]) -> Void
    private let backingScale: CGFloat

    private var phase: Phase = .select
    private var phaseStarted = Date()
    private var targetPosition = CGPoint.zero
    private var pointsLeft = false

    private var background: CGImage?
    private var sprites: [SpriteKey: Sprite] = [:]
    private var audio: Audio?

    private var explosionStarted: Date?
    private var explosionPositions: [CGPoint] = []
    private var failures: [URL: Error] = [:]

    private var timer: Timer?
    private var didFirstTick = false
    private var preloadStarted = false
    private var lastVisualKey: Int?
    private var textCache: [TextKey: (line: NSAttributedString, height: CGFloat)] = [:]
    private var snapshotsTaken: Set<String> = []

    init(
        frame: NSRect,
        targets: [URL],
        options: RunOptions,
        backingScale: CGFloat,
        onFinish: @escaping ([URL: Error]) -> Void
    ) {
        self.targets = targets
        self.options = options
        self.backingScale = backingScale
        self.onFinish = onFinish
        self.trash = options.deletionEnabled ? OverlayView.moveToTrash : { _ in [:] }
        super.init(frame: frame)
        targetPosition = CGPoint(x: frame.width / 2, y: frame.height / 2)
        // Pre-composited at screen size with the dimming baked in: rescaling
        // the 1375×768 source every frame, and drawing it through a global
        // alpha, each cost tens of milliseconds per frame.
        background = Self.makeBackground(size: frame.size, scale: backingScale)
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
        audio?.stopAll()
        onFinish(failures)
    }

    /// Started once the user has marked a target: decoding six sheets and
    /// bringing up CoreAudio while the selection screen is still fading in
    /// competes with the main thread, and none of it is needed for 0.5s.
    private func preload() {
        guard !preloadStarted else { return }
        preloadStarted = true

        if options.audioEnabled {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let audio = Audio()
                DispatchQueue.main.async { self?.audio = audio }
            }
        }

        // Split by when each sheet is first drawn. Decoding all six at once
        // saturates the machine and starves the 0.5s fade-out of frames; the
        // last four are not needed for another five seconds.
        let soon: [(file: String, height: CGFloat, key: SpriteKey)] = [
            ("走路动效_spritesheet_transparent.png", Layout.monsterHeight, .walk),
            ("指着文件_spritesheet_transparent.png", Layout.monsterHeight, .point),
        ]
        let later: [(file: String, height: CGFloat, key: SpriteKey)] = [
            ("踹文件动效_spritesheet_transparent.png", Layout.monsterHeight, .kick),
            ("雷欧登场_spritesheet_transparent.png", Layout.monsterHeight, .leo),
            ("出场飞行动效_spritesheet_transparent.png", Layout.monsterHeight, .fly),
            ("爆炸_spritesheet_transparent.png", Layout.explosionHeight, .explosion),
        ]
        load(soon, qos: .userInitiated)
        load(later, qos: .utility)
    }

    private func load(
        _ specs: [(file: String, height: CGFloat, key: SpriteKey)],
        qos: DispatchQoS.QoSClass
    ) {
        let scale = backingScale
        DispatchQueue.global(qos: qos).async { [weak self] in
            DispatchQueue.concurrentPerform(iterations: specs.count) { index in
                let spec = specs[index]
                let sprite = Sprite.load(Assets.url(spec.file), height: spec.height, scale: scale)
                DispatchQueue.main.async { self?.sprites[spec.key] = sprite }
            }
        }
    }

    private static func makeBackground(size: CGSize, scale: CGFloat) -> CGImage? {
        guard let source = Sprite.loadImage(Assets.url("选择界面", "选择界面.png")) else { return nil }
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        return Bitmap.make(width: pixelWidth, height: pixelHeight) { context in
            // Cover: fill the screen, cropping the overflow evenly.
            let cover = max(
                CGFloat(pixelWidth) / CGFloat(source.width),
                CGFloat(pixelHeight) / CGFloat(source.height)
            )
            let width = CGFloat(source.width) * cover
            let height = CGFloat(source.height) * cover
            context.setAlpha(CGFloat(selectionOpacity))
            context.draw(
                source,
                in: CGRect(
                    x: (CGFloat(pixelWidth) - width) / 2,
                    y: (CGFloat(pixelHeight) - height) / 2,
                    width: width,
                    height: height
                )
            )
        }
    }

    // MARK: - Phase machine

    private var elapsed: Double { Date().timeIntervalSince(phaseStarted) }
    private var frameIndex: Int { max(0, Int(elapsed * frameRate)) }

    private func enter(_ next: Phase) {
        phase = next
        phaseStarted = Date()
        if next == .walk { background = nil } // 20MB, never drawn again
        window?.invalidateCursorRects(for: self)
    }

    private func tick() {
        if !didFirstTick {
            didFirstTick = true
            if options.snapshotDirectory != nil {
                FileHandle.standardError.write(
                    Data("[monster] first tick at \(String(format: "%.3f", elapsed))s\n".utf8)
                )
            }
            // Putting a full-screen transparent window on screen takes a while
            // and nothing repaints until it lands. Restart the clock so the
            // fade-in plays from the beginning instead of snapping to its
            // midpoint.
            phaseStarted = Date()
        }

        if let autoplayPoint = options.autoplayPoint {
            if phase == .select, elapsed >= 1.5 {
                handleClick(at: autoplayPoint)
            } else if phase == .ask, elapsed >= 1.0 {
                let button = choiceRects()[0]
                handleClick(at: CGPoint(x: button.midX, y: button.midY))
            }
        }

        switch phase {
        case .fadeOut where elapsed >= Timing.fadeOut:
            // Play on without the monster rather than hang if a sheet is bad.
            guard sprites[.walk] != nil || elapsed >= Timing.fadeOut + Timing.assetWait else { break }
            audio?.play("bgm", loop: true)
            enter(.walk)
        case .walk where elapsed >= Timing.walk:
            // The question SFX starts with the pointing animation and carries
            // into the bubble; it is not restarted when the bubble appears.
            audio?.play("talk")
            enter(.point)
        case .point where elapsed >= Timing.point:
            enter(.ask)
        case .kick:
            if frameIndex >= Timing.deleteAtFrame, explosionStarted == nil { triggerDelete() }
            if elapsed >= Timing.sheet { enter(.leo) }
        case .leo where elapsed >= Timing.sheet:
            enter(.fly)
        case .fly where elapsed >= Timing.fly:
            finish()
            return
        default:
            break
        }

        // Repaint only when the picture actually changes: sprite frames step
        // at 8fps and `.ask` is static until the user answers.
        let key = visualKey()
        if key != lastVisualKey {
            lastVisualKey = key
            needsDisplay = true
        }
        captureSnapshotIfNeeded()
    }

    private func visualKey() -> Int {
        switch phase {
        case .select:
            let progress = min(elapsed / Timing.selectFadeIn, 1)
            return progress >= 1 ? -1 : Int(progress * 1000)
        case .fadeOut:
            return Int(min(elapsed / Timing.fadeOut, 1) * 1000)
        case .walk, .fly:
            return Int(elapsed * 1000)
        case .point, .ask, .leo:
            return frameIndex
        case .kick:
            let since = explosionStarted.map { Date().timeIntervalSince($0) } ?? -1
            let explosionFrame = (since >= 0 && since <= Timing.sheet) ? Int(since * frameRate) : -1
            return frameIndex * 100 + explosionFrame
        }
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

    private static func moveToTrash(_ urls: [URL]) -> [URL: Error] {
        var failures: [URL: Error] = [:]
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failures[url] = error
            }
        }
        return failures
    }

    private func triggerDelete() {
        explosionStarted = Date()
        explosionPositions = explosionPositionsForDelete()
        audio?.play("boom")
        failures = trash(targets)
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
        let anchor: CGRect
        if let sprite = sprites[.point] {
            let position = monsterPosition(sprite)
            anchor = CGRect(
                origin: position,
                size: CGSize(width: sprite.width, height: sprite.height)
            )
        } else {
            anchor = CGRect(
                origin: targetPosition,
                size: CGSize(width: Layout.monsterHeight, height: Layout.monsterHeight)
            )
        }

        let margin = Layout.choiceMargin
        let x = clamp(
            anchor.midX - Layout.choiceGroupWidth / 2,
            margin,
            bounds.width - Layout.choiceGroupWidth - margin
        )
        let below = anchor.maxY + Layout.choiceHeight + 16 <= bounds.height - margin
        let y = below ? anchor.maxY + 16 : max(anchor.minY - Layout.choiceHeight - 16, margin)
        return [
            CGRect(x: x, y: y, width: Layout.firstChoiceWidth, height: Layout.choiceHeight),
            CGRect(
                x: x + Layout.firstChoiceWidth + Layout.choiceGap,
                y: y,
                width: Layout.secondChoiceWidth,
                height: Layout.choiceHeight
            ),
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
            drawSelection(context, progress: min(elapsed / Timing.selectFadeIn, 1))
        case .fadeOut:
            drawSelection(context, progress: max(1 - elapsed / Timing.fadeOut, 0))
        case .walk:
            drawWalk(context)
        case .point:
            if let sprite = sprites[.point] {
                drawSprite(context, sprite, frame: 11 + min(frameIndex, 3), at: monsterPosition(sprite))
            }
        case .ask:
            drawAsk(context)
        case .kick:
            if let sprite = sprites[.kick] {
                drawSprite(
                    context,
                    sprite,
                    frame: min(frameIndex, Sprite.frameCount - 1),
                    at: monsterPosition(sprite)
                )
            }
            drawExplosion(context)
        case .leo:
            if let sprite = sprites[.leo] {
                drawSprite(
                    context,
                    sprite,
                    frame: min(frameIndex, Sprite.frameCount - 1),
                    at: monsterPosition(sprite)
                )
            }
        case .fly:
            drawFly(context)
        }
    }

    private func drawSelection(_ context: CGContext, progress: Double) {
        if let background {
            if progress >= 1 {
                // Steady state: a straight copy, no global alpha. The same
                // draw through `setAlpha` measured ~44ms per frame.
                context.saveGState()
                context.setBlendMode(.copy)
                draw(context, image: background, in: bounds, alpha: 1)
                context.restoreGState()
            } else {
                draw(context, image: background, in: bounds, alpha: CGFloat(progress))
            }
        } else {
            context.setFillColor(NSColor(white: 0, alpha: CGFloat(progress) * 0.63).cgColor)
            context.fill(bounds)
        }

        drawText(
            context,
            "请选择你要摧毁的文件",
            in: CGRect(x: bounds.width / 2 - 300, y: bounds.height / 2 - 28, width: 600, height: 56),
            size: 30,
            color: .white,
            alpha: CGFloat(progress)
        )
    }

    private func drawWalk(_ context: CGContext) {
        guard let sprite = sprites[.walk] else { return }
        let progress = min(elapsed / Timing.walk, 1)
        let end = monsterPosition(sprite)
        let startX = pointsLeft ? bounds.width : -sprite.width
        let eased = 1 - (1 - progress) * (1 - progress)
        let x = startX + (end.x - startX) * CGFloat(eased)
        drawSprite(context, sprite, frame: frameIndex, at: CGPoint(x: x, y: end.y))
    }

    private func drawAsk(_ context: CGContext) {
        guard let sprite = sprites[.point] else { return }
        let position = monsterPosition(sprite)
        drawSprite(context, sprite, frame: Sprite.frameCount - 1, at: position)
        drawBubble(context, sprite: sprite, at: position)
    }

    private func drawFly(_ context: CGContext) {
        guard let sprite = sprites[.fly] else { return }
        let progress = CGFloat(min(elapsed / Timing.fly, 1))
        let start = monsterPosition(sprite)
        let endX = pointsLeft ? -sprite.width - 200 : bounds.width + 200
        let x = start.x + (endX - start.x) * progress * progress
        drawSprite(context, sprite, frame: frameIndex, at: CGPoint(x: x, y: start.y))
    }

    private func drawExplosion(_ context: CGContext) {
        guard let started = explosionStarted, let sprite = sprites[.explosion] else { return }
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

    private func drawBubble(_ context: CGContext, sprite: Sprite, at position: CGPoint) {
        let message = targets.count > 1 ? "喂，是这些吗？" : "喂，是这个吗？"
        let choiceTitles = ["是的", targets.count > 1 ? "嘤嘤嘤就是这些" : "嘤嘤嘤就是这个"]

        let width = Layout.bubbleWidth
        let height: CGFloat = 64
        let margin = Layout.bubbleMargin
        let tail = Layout.bubbleTail

        let rawX = pointsLeft ? position.x + sprite.width + 18 : position.x - width - 18
        let x = clamp(rawX, margin, bounds.width - width - margin)
        let sideY = position.y + sprite.height * 0.3 - height / 2
        let below = sideY < margin
        let y = clamp(
            below ? position.y + sprite.height + 20 : sideY,
            margin,
            bounds.height - height - margin
        )
        let bubble = CGRect(x: x, y: y, width: width, height: height)

        let targetY = clamp(position.y + sprite.height / 2, y + tail, y + height - tail)
        let corners: (CGPoint, CGPoint, CGPoint)
        if below {
            corners = (
                CGPoint(x: bubble.midX - tail, y: y),
                CGPoint(x: bubble.midX + tail, y: y),
                CGPoint(x: bubble.midX, y: y - tail)
            )
        } else if pointsLeft {
            corners = (
                CGPoint(x: x, y: targetY - tail),
                CGPoint(x: x, y: targetY + tail),
                CGPoint(x: x - tail, y: targetY)
            )
        } else {
            corners = (
                CGPoint(x: bubble.maxX, y: targetY - tail),
                CGPoint(x: bubble.maxX, y: targetY + tail),
                CGPoint(x: bubble.maxX + tail, y: targetY)
            )
        }

        let shadowDrop: CGFloat = 7
        drawTriangle(
            context,
            CGPoint(x: corners.0.x, y: corners.0.y + shadowDrop),
            CGPoint(x: corners.1.x, y: corners.1.y + shadowDrop),
            CGPoint(x: corners.2.x, y: corners.2.y + shadowDrop),
            color: Palette.tailShadow
        )
        drawTriangle(context, corners.0, corners.1, corners.2, color: Palette.card)
        drawCard(context, rect: bubble, radius: 20, shadowOffset: 8, shadowBlur: 14)
        drawText(context, message, in: bubble, size: 20, color: Palette.ink)

        for (rect, title) in zip(choiceRects(), choiceTitles) {
            drawCard(context, rect: rect, radius: 18, shadowOffset: 5, shadowBlur: 10)
            drawText(context, title, in: rect, size: 16, color: Palette.ink)
        }
    }

    // MARK: - Primitives

    private enum Palette {
        static let card = NSColor(white: 1, alpha: 240.0 / 255.0)
        static let ink = NSColor(white: 28.0 / 255.0, alpha: 1)
        static let tailShadow = NSColor(white: 0, alpha: 28.0 / 255.0)
        static let cardShadow = NSColor(white: 0, alpha: 0.11)
    }

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
        if alpha < 1 { context.setAlpha(alpha) }
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
            color: Palette.cardShadow.cgColor
        )
        context.setFillColor(Palette.card.cgColor)
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

    private struct TextKey: Hashable {
        let text: String
        let size: CGFloat
        let color: NSColor
    }

    /// The strings and their metrics are constant; only the selection prompt's
    /// alpha varies, so that rides on the context instead of a new string.
    private func drawText(
        _ context: CGContext,
        _ text: String,
        in rect: CGRect,
        size: CGFloat,
        color: NSColor,
        alpha: CGFloat = 1
    ) {
        guard alpha > 0 else { return }
        let key = TextKey(text: text, size: size, color: color)
        let entry: (line: NSAttributedString, height: CGFloat)
        if let cached = textCache[key] {
            entry = cached
        } else {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byWordWrapping
            let line = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: .medium),
                    .foregroundColor: color,
                    .paragraphStyle: style,
                ]
            )
            let measured = line.boundingRect(
                with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin]
            )
            entry = (line, measured.height)
            textCache[key] = entry
        }

        context.saveGState()
        if alpha < 1 { context.setAlpha(alpha) }
        entry.line.draw(
            with: CGRect(
                x: rect.minX,
                y: rect.minY + (rect.height - entry.height) / 2,
                width: rect.width,
                height: entry.height
            ),
            options: [.usesLineFragmentOrigin]
        )
        context.restoreGState()
    }

    // MARK: - Self test

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
        guard let directory = options.snapshotDirectory else { return }
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
        // transparent pixel white. Render into an explicit RGBA buffer, over
        // grey, so transparency stays readable.
        guard let layer = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * backingScale),
            pixelsHigh: Int(bounds.height * backingScale),
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
            flipped.cgContext.setBlendMode(.destinationOver)
            flipped.cgContext.setFillColor(NSColor(white: 0.25, alpha: 1).cgColor)
            flipped.cgContext.fill(bounds)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let png = layer.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
