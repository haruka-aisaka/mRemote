import Foundation

/// A server-supplied pointer image, premultiplied BGRA, top row first.
///
/// Premultiplied because that is the only BGRA layout Core Graphics draws;
/// the conversion happens once, when the server sends the shape, rather than
/// on every pointer move.
public struct RemoteCursorImage: Hashable, Sendable {
    public static let maximumDimension = 384

    public let width: Int
    public let height: Int
    public let hotspotX: Int
    public let hotspotY: Int
    public let pixels: Data

    public var bytesPerRow: Int { width * 4 }

    /// Copies `width`×`height` straight-alpha BGRA pixels out of a buffer of
    /// `sourceBytesPerRow`, premultiplying as it goes. Nil when the geometry
    /// does not describe the buffer: this is the second bounds check on data
    /// that arrived over the network, and it is the one that decides how many
    /// bytes are read.
    public init?(
        straightBGRA source: UnsafeRawBufferPointer,
        width: Int,
        height: Int,
        sourceBytesPerRow: Int,
        hotspotX: Int,
        hotspotY: Int
    ) {
        guard width > 0, height > 0,
              width <= Self.maximumDimension, height <= Self.maximumDimension,
              sourceBytesPerRow >= width * 4,
              source.count >= sourceBytesPerRow * (height - 1) + width * 4,
              (0..<width).contains(hotspotX), (0..<height).contains(hotspotY) else {
            return nil
        }
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { destination in
            for row in 0..<height {
                for column in 0..<width {
                    let input = row * sourceBytesPerRow + column * 4
                    let output = (row * width + column) * 4
                    let alpha = UInt16(source[input + 3])
                    for channel in 0..<3 {
                        destination[output + channel] =
                            UInt8((UInt16(source[input + channel]) * alpha + 127) / 255)
                    }
                    destination[output + 3] = UInt8(alpha)
                }
            }
        }
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.pixels = pixels
    }
}

public enum RemoteCursor: Hashable, Sendable {
    /// The server asked for its default arrow; the local system pointer is
    /// the closest thing to it.
    case systemDefault
    case hidden
    case shape(RemoteCursorImage)
}

/// The latest cursor, for the surface to pick up. Like frames, cursors have
/// no history worth replaying: only the newest one matters, and the protocol
/// worker must never wait for the main thread to take it.
public final class RemoteCursorStore: @unchecked Sendable {
    public typealias Signal = @Sendable () -> Void

    private let lock = NSLock()
    private var current: RemoteCursor = .systemDefault
    private var signal: Signal?

    public init() {}

    public var cursor: RemoteCursor {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func setSignal(_ signal: Signal?) {
        lock.lock()
        self.signal = signal
        lock.unlock()
    }

    public func submit(_ cursor: RemoteCursor) {
        lock.lock()
        guard cursor != current else {
            lock.unlock()
            return
        }
        current = cursor
        let signal = self.signal
        lock.unlock()
        signal?()
    }

    /// Back to the system arrow, e.g. when a connection ends.
    public func reset() {
        submit(.systemDefault)
    }
}
