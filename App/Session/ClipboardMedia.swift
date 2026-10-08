import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import SessionCore

/// Images and files between the device and the remote clipboard.
enum ClipboardMedia {
    /// PNG for programs that take it, and CF_DIB - a BITMAPINFOHEADER and
    /// bottom-up BGRA rows - for every Windows program that pastes images.
    static func encode(_ image: UIImage) -> (png: Data?, dib: Data?) {
        guard let cgImage = image.cgImage else { return (image.pngData(), nil) }
        return (image.pngData(), dib(from: cgImage))
    }

    static func dib(from image: CGImage) -> Data? {
        let width = image.width
        let height = image.height
        let stride = width * 4
        var pixels = [UInt8](repeating: 0, count: stride * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            // Core Graphics draws bottom-up, which is the order a DIB wants.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var data = Data(capacity: 40 + pixels.count)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(40))            // biSize
        append(Int32(width))          // biWidth
        append(Int32(height))         // biHeight: positive, bottom-up
        append(UInt16(1))             // biPlanes
        append(UInt16(32))            // biBitCount
        append(UInt32(0))             // BI_RGB
        append(UInt32(pixels.count))  // biSizeImage
        append(Int32(2835))           // 72 dpi
        append(Int32(2835))
        append(UInt32(0))
        append(UInt32(0))
        data.append(contentsOf: pixels)
        return data
    }

    /// A remote image as something UIKit shows: PNG as it is, a DIB with the
    /// BMP file header it lacks.
    static func image(from remote: RemoteClipboardImage) -> UIImage? {
        switch remote {
        case .png(let data):
            return UIImage(data: data)
        case .dib(let dib):
            guard dib.count >= 40 else { return nil }
            let headerSize = dib.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            let bitCount = dib.dropFirst(14).prefix(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }
            let compression = dib.dropFirst(16).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            let colorsUsed = dib.dropFirst(32).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            // Palette or BI_BITFIELDS masks sit between the header and pixels.
            var extra = Int(colorsUsed) * 4
            if colorsUsed == 0, bitCount <= 8 { extra = (1 << Int(bitCount)) * 4 }
            if compression == 3, headerSize == 40 { extra += 12 }
            var file = Data([0x42, 0x4D])
            let offset = UInt32(14 + Int(headerSize) + extra)
            withUnsafeBytes(of: UInt32(14 + dib.count).littleEndian) { file.append(contentsOf: $0) }
            file.append(contentsOf: [0, 0, 0, 0])
            withUnsafeBytes(of: offset.littleEndian) { file.append(contentsOf: $0) }
            file.append(dib)
            guard let source = CGImageSourceCreateWithData(file as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return UIImage(cgImage: image)
        }
    }

    /// Received files go to Documents/受信, which the Files app shows under
    /// "mRemote"; a name already there gets a number.
    static func save(_ files: [ClipboardFile]) throws -> URL {
        let folder = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent(String(localized: "受信"), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            let safe = file.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            var target = folder.appendingPathComponent(safe)
            var counter = 2
            while FileManager.default.fileExists(atPath: target.path) {
                let base = (safe as NSString).deletingPathExtension
                let ext = (safe as NSString).pathExtension
                target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)")
                counter += 1
            }
            try file.data.write(to: target, options: .atomic)
        }
        return folder
    }

    /// Picked files, read while their security scope is open.
    static func read(_ urls: [URL]) -> [ClipboardFile] {
        urls.compactMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ClipboardFile(name: url.lastPathComponent, data: data)
        }
    }
}
