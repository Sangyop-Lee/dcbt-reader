// Draws the app icon PNGs. Usage: swiftc make_icon.swift -o make_icon && ./make_icon AppIcon.iconset && iconutil -c icns AppIcon.iconset
import AppKit
let out = CommandLine.arguments[1]
let sizes = [16, 32, 64, 128, 256, 512, 1024]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for px in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.19, yRadius: s * 0.19)
    // off-white tile with a hairline edge, so it stays visible on white backgrounds
    NSGradient(colors: [NSColor(srgbRed: 0.985, green: 0.980, blue: 0.965, alpha: 1), NSColor(srgbRed: 0.945, green: 0.935, blue: 0.905, alpha: 1)])!
        .draw(in: path, angle: -90)
    NSColor(srgbRed: 0.80, green: 0.78, blue: 0.73, alpha: 1).setStroke()
    path.lineWidth = max(s * 0.006, 0.5)
    path.stroke()
    let font = NSFont(name: "Songti TC Bold", size: s * 0.56) ?? NSFont.boldSystemFont(ofSize: s * 0.56)
    let str = NSAttributedString(string: "藏", attributes: [.font: font, .foregroundColor: NSColor(srgbRed: 0.55, green: 0.12, blue: 0.10, alpha: 1)])
    // centre the ink of the character itself, not its line box: draw it as a
    // glyph path, whose bounds are exact
    let line = CTLineCreateWithAttributedString(str)
    let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.textPosition = CGPoint(x: s / 2 - ink.midX, y: s / 2 - ink.midY)
    CTLineDraw(line, ctx)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    func write(_ name: String) { try! data.write(to: URL(fileURLWithPath: out + "/" + name)) }
    switch px {
    case 16: write("icon_16x16.png")
    case 32: write("icon_16x16@2x.png"); write("icon_32x32.png")
    case 64: write("icon_32x32@2x.png")
    case 128: write("icon_128x128.png")
    case 256: write("icon_128x128@2x.png"); write("icon_256x256.png")
    case 512: write("icon_256x256@2x.png"); write("icon_512x512.png")
    default: write("icon_512x512@2x.png")
    }
}
