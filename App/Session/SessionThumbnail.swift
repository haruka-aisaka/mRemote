import CoreGraphics
import SessionCore
import UIKit

/// A small picture of a session's desktop for the list and the switcher.
///
/// Kept in memory only: a screenshot of someone's desktop is not something
/// to leave on disk.
enum SessionThumbnail {
    static let maximumWidth: CGFloat = 480

    static func make(from frame: DesktopFrame) -> UIImage? {
        guard frame.width > 0, frame.height > 0,
              let provider = CGDataProvider(data: frame.pixels as CFData),
              let full = CGImage(
                width: frame.width,
                height: frame.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: frame.bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        let scale = min(1, maximumWidth / CGFloat(frame.width))
        let size = CGSize(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.interpolationQuality = .medium
            // UIKit's context is flipped relative to Core Graphics'.
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            context.cgContext.draw(full, in: CGRect(origin: .zero, size: size))
        }
    }
}
