// color-boxes: スクリーンショットの中で、目印の窓（macos-rdp-server の tests/e2e/e2e-target.swift）の
// 色がどこにあるかを JSON で出す。
//
//   color-boxes <png>
//
// 色ごとに、近い色の画素の数と、それを囲む矩形（画素）。H.264 を通るので色は少しずれる。
import CoreGraphics
import Foundation
import ImageIO

let palette: [(name: String, rgb: (Double, Double, Double))] = [
    ("background", (16, 160, 80)),
    ("topLeft", (255, 0, 0)),
    ("topRight", (255, 255, 0)),
    ("bottomLeft", (0, 0, 255)),
    ("bottomRight", (255, 0, 255)),
]
let tolerance = 70.0

guard CommandLine.arguments.count == 2,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("usage: color-boxes <png>\n".utf8))
    exit(2)
}
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let context = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

struct Box {
    var count = 0
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
}
var boxes = [Box](repeating: Box(), count: palette.count)
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
        var best = -1
        var bestDistance = tolerance
        for (index, color) in palette.enumerated() {
            let d = ((r - color.rgb.0) * (r - color.rgb.0) + (g - color.rgb.1) * (g - color.rgb.1)
                + (b - color.rgb.2) * (b - color.rgb.2)).squareRoot()
            if d < bestDistance {
                bestDistance = d
                best = index
            }
        }
        guard best >= 0 else { continue }
        boxes[best].count += 1
        boxes[best].minX = min(boxes[best].minX, x)
        boxes[best].minY = min(boxes[best].minY, y)
        boxes[best].maxX = max(boxes[best].maxX, x)
        boxes[best].maxY = max(boxes[best].maxY, y)
    }
}
var output: [String: Any] = ["width": width, "height": height]
for (index, color) in palette.enumerated() {
    let box = boxes[index]
    output[color.name] = box.count == 0 ? ["count": 0] : [
        "count": box.count, "x": box.minX, "y": box.minY,
        "w": box.maxX - box.minX + 1, "h": box.maxY - box.minY + 1,
    ]
}
let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
