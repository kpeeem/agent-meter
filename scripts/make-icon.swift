import CoreGraphics
import Foundation
import ImageIO

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let sizes = [16, 32, 64, 128, 256, 512, 1024]
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "com.apple.icns" as CFString,
                                                        sizes.count, nil) else {
    throw CocoaError(.fileWriteUnknown)
}
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(size: Int) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let tile = CGRect(x: 92, y: 92, width: 840, height: 840)
    context.addPath(rounded(tile, radius: 192))
    context.setFillColor(color(0.10, 0.16, 0.19))
    context.fillPath()
    context.addPath(rounded(tile.insetBy(dx: 9, dy: 9), radius: 183))
    context.setStrokeColor(color(0.68, 0.80, 0.77, 0.24))
    context.setLineWidth(9)
    context.strokePath()

    for (index, height) in [252, 415, 518].enumerated() {
        let x = CGFloat(286 + index * 167)
        let bar = CGRect(x: x, y: 252, width: 118, height: CGFloat(height))
        context.addPath(rounded(bar, radius: 45))
        context.setFillColor(index == 2 ? color(0.97, 0.68, 0.35) : color(0.78, 0.90, 0.85))
        context.fillPath()
    }

    return context.makeImage()!
}

for size in sizes {
    CGImageDestinationAddImage(destination, render(size: size), nil)
}
guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
