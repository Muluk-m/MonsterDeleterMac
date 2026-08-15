import AppKit

/// A 5×3 sprite sheet sliced into 15 frames, pre-scaled to the size it is
/// drawn at.
struct Sprite {
    static let columns = 5
    static let rows = 3
    static let frameCount = columns * rows

    let frames: [CGImage]
    let width: CGFloat
    let height: CGFloat

    func frame(_ index: Int) -> CGImage { frames[index % frames.count] }

    /// - Parameters:
    ///   - height: drawn height in points.
    ///   - scale: backing-store factor of the screen the overlay is on.
    static func load(_ url: URL, height: CGFloat, scale: CGFloat) -> Sprite? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = decodeSheet(source, fitting: height * scale * CGFloat(rows))
        else { return nil }

        // Fractional tiling: a downsampled sheet need not divide evenly.
        let sourceFrameWidth = CGFloat(sheet.width) / CGFloat(columns)
        let sourceFrameHeight = CGFloat(sheet.height) / CGFloat(rows)
        guard sourceFrameWidth >= 1, sourceFrameHeight >= 1 else { return nil }

        let drawnWidth = (sourceFrameWidth * height / sourceFrameHeight).rounded()
        let pixelWidth = Int((drawnWidth * scale).rounded())
        let pixelHeight = Int((height * scale).rounded())

        var frames: [CGImage] = []
        frames.reserveCapacity(frameCount)
        for row in 0..<rows {
            for column in 0..<columns {
                // Inset by a pixel: the sheets carry a faint seam on the frame
                // boundary, which reads as a hairline next to the artwork.
                let crop = CGRect(
                    x: CGFloat(column) * sourceFrameWidth,
                    y: CGFloat(row) * sourceFrameHeight,
                    width: sourceFrameWidth,
                    height: sourceFrameHeight
                ).insetBy(dx: 1, dy: 1)
                guard let cropped = sheet.cropping(to: crop),
                      let scaled = Bitmap.make(width: pixelWidth, height: pixelHeight, { context in
                          context.draw(
                              cropped,
                              in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
                          )
                      })
                else { return nil }
                frames.append(scaled)
            }
        }
        return Sprite(frames: frames, width: drawnWidth, height: height)
    }

    /// Decoding the explosion sheet at its native 7200×5760 costs ~750ms and
    /// ~166MB to produce frames drawn at 226×300. Ask ImageIO for a sheet just
    /// big enough for the frames we need instead.
    private static func decodeSheet(_ source: CGImageSource, fitting sheetHeight: CGFloat) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let sourceWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let sourceHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              sourceWidth > 0, sourceHeight > 0
        else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }

        let neededWidth = sheetHeight * CGFloat(sourceWidth) / CGFloat(sourceHeight)
        let maxPixelSize = Int(max(neededWidth, sheetHeight).rounded(.up))
        guard Double(maxPixelSize) < max(sourceWidth, sourceHeight) else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
