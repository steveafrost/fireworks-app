// Draws the Fireworks app icon at every size the App Store asks for.
//
//   swift Tools/make-icon.swift <output-directory>
//
// The icon is the app's own idea of itself: a credit ring, mostly spent, with
// the dollar amount at the centre. Drawn rather than painted so the small
// sizes stay legible — each size is rasterised from vectors, never downscaled.
//
// App Store icons must have no alpha channel, so every bitmap here is opaque.

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

/// Mocha-ish palette, matching the app's UI.
let base = CGColor(red: 0.086, green: 0.078, blue: 0.125, alpha: 1)      // #16141f
let glow = CGColor(red: 0.176, green: 0.145, blue: 0.259, alpha: 1)      // #2d2542
let track = CGColor(red: 1, green: 1, blue: 1, alpha: 0.13)
let arcStart = CGColor(red: 0.796, green: 0.651, blue: 0.969, alpha: 1)  // #cba6f7 mauve
let arcEnd = CGColor(red: 0.537, green: 0.706, blue: 0.980, alpha: 1)    // #89b4fa blue
let ink = CGColor(red: 0.925, green: 0.937, blue: 0.957, alpha: 1)       // #ecEEF4

func drawIcon(size: CGFloat) -> CGImage? {
    let px = Int(size)
    guard let ctx = CGContext(data: nil, width: px, height: px,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Squircle-ish background with a soft centre glow, filling the whole canvas:
    // the OS applies the mask, so bleeding to the edges is what it expects.
    let corner = size * 0.2237
    let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                    cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.addPath(bg)
    ctx.clip()
    ctx.setFillColor(base)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    let radial = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [glow, base] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(radial,
                           startCenter: CGPoint(x: size / 2, y: size * 0.56), startRadius: 0,
                           endCenter: CGPoint(x: size / 2, y: size * 0.5), endRadius: size * 0.66,
                           options: [])
    ctx.restoreGState()

    // The credit ring: a full track, and an arc for what has been spent.
    let centre = CGPoint(x: size / 2, y: size / 2)
    let radius = size * 0.315
    let width = size * 0.098
    let spent: CGFloat = 0.85

    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(track)
    ctx.addArc(center: centre, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    ctx.saveGState()
    let arc = CGMutablePath()
    arc.addArc(center: centre, radius: radius,
               startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2 * spent, clockwise: true)
    ctx.addPath(arc)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let sweep = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [arcStart, arcEnd] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sweep,
                           start: CGPoint(x: size * 0.15, y: size * 0.85),
                           end: CGPoint(x: size * 0.85, y: size * 0.15),
                           options: [])
    ctx.restoreGState()

    // The amount, as a dollar sign: legible at 16pt, where the ring is a smudge.
    let font = CTFontCreateWithName("SFProRounded-Bold" as CFString, size * 0.30, nil)
    // CoreText attribute keys, not AppKit's: this generator has no UI framework
    // loaded, so `.foregroundColor` does not exist.
    let text = NSAttributedString(string: "$", attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
    ])
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    ctx.textPosition = CGPoint(x: centre.x - bounds.width / 2 - bounds.minX,
                               y: centre.y - bounds.height / 2 - bounds.minY)
    CTLineDraw(line, ctx)

    return ctx.makeImage()
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let sizes: [(String, CGFloat)] = [
    ("icon-1024", 1024), ("icon-512", 512), ("icon-256", 256),
    ("icon-128", 128), ("icon-64", 64), ("icon-32", 32), ("icon-16", 16),
]

for (name, size) in sizes {
    guard let image = drawIcon(size: size) else {
        FileHandle.standardError.write("failed to draw \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    write(image, to: "\(outDir)/\(name).png")
    print("wrote \(outDir)/\(name).png")
}
