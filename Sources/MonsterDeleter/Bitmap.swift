import CoreGraphics

/// One place that knows the pixel format every generated image uses.
enum Bitmap {
    static func make(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        body(context)
        return context.makeImage()
    }
}
