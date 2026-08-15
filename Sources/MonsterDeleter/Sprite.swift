import AppKit

/// A 5×3 sprite sheet sliced into 15 frames, pre-scaled to the size it is
/// drawn at. The explosion sheet is 7200×5760, so keeping the frames at their
/// source resolution would cost hundreds of megabytes for no visible gain.
struct Sprite {
    static let columns = 5
    static let rows = 3
    static let frameCount = columns * rows

    let frames: [CGImage]
    let width: CGFloat
    let height: CGFloat

    func frame(_ index: Int) -> CGImage {
        frames[((index % frames.count) + frames.count) % frames.count]
    }

    /// - Parameters:
    ///   - height: drawn height in points.
    ///   - scale: backing-store factor; 2 keeps the frames crisp on Retina.
    static func load(_ url: URL, height: CGFloat, scale: CGFloat = 2) -> Sprite? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let frameWidth = sheet.width / columns
        let frameHeight = sheet.height / rows
        guard frameWidth > 0, frameHeight > 0 else { return nil }

        let drawnWidth = (CGFloat(frameWidth) * height / CGFloat(frameHeight)).rounded()
        let pixelWidth = Int((drawnWidth * scale).rounded())
        let pixelHeight = Int((height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        var frames: [CGImage] = []
        frames.reserveCapacity(frameCount)
        for row in 0..<rows {
            for column in 0..<columns {
                let crop = CGRect(
                    x: column * frameWidth,
                    y: row * frameHeight,
                    width: frameWidth,
                    height: frameHeight
                )
                guard let cropped = sheet.cropping(to: crop),
                      let context = CGContext(
                          data: nil,
                          width: pixelWidth,
                          height: pixelHeight,
                          bitsPerComponent: 8,
                          bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      )
                else { continue }
                context.interpolationQuality = .high
                context.draw(cropped, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                if let scaled = context.makeImage() { frames.append(scaled) }
            }
        }
        guard frames.count == frameCount else { return nil }
        return Sprite(frames: frames, width: drawnWidth, height: height)
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
