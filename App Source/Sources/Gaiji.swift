import AppKit
import CoreText

/// Characters the Mac's fonts cannot draw. CBETA publishes a supplementary
/// font for the ones that are in Unicode, and small images for the ones that
/// are not (rare ideographs, Siddham and Rañjanā letters). Both live in the
/// "Gaiji" folder beside the app.
final class GaijiStore {
    static let shared = GaijiStore()
    private var index: [String: (Int, Int)] = [:]
    private var data: Data?
    private var masks: [String: CGImage] = [:]
    private let lock = NSLock()
    private var supplement: NSFontDescriptor?


    private init() {
        guard let dir = AppPaths.gaijiDir else { return }
        let f = dir.appendingPathComponent("CBETASupplement.ttf")
        if FileManager.default.fileExists(atPath: f.path) {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            if let ds = CTFontManagerCreateFontDescriptorsFromURL(f as CFURL) as? [CTFontDescriptor], let d = ds.first {
                supplement = d as NSFontDescriptor
            }
        }
        if let d = try? Data(contentsOf: dir.appendingPathComponent("glyphs.bin"), options: .alwaysMapped),
           let t = try? String(contentsOf: dir.appendingPathComponent("glyphs.idx"), encoding: .utf8) {
            data = d
            t.enumerateLines { line, _ in
                let p = line.split(separator: "\t")
                if p.count == 3, let o = Int(p[1]), let n = Int(p[2]), o + n <= d.count { self.index[String(p[0])] = (o, n) }
            }
        }
    }

    /// A font that falls back to CBETA's supplementary font for rare characters.
    func font(_ name: String, size: CGFloat) -> NSFont {
        let base = NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
        guard let sup = supplement else { return base }
        let d = base.fontDescriptor.addingAttributes([.cascadeList: [sup]])
        return NSFont(descriptor: d, size: size) ?? base
    }

    private func mask(_ id: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let m = masks[id] { return m }
        guard let (o, n) = index[id], let d = data,
              let rep = NSBitmapImageRep(data: d.subdata(in: o..<(o + n))), let cg = rep.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(r)
        ctx.draw(cg, in: r)
        // dark strokes on a light ground: used as a stencil, so the glyph takes the text colour
        guard let gray = ctx.makeImage(), let p = gray.dataProvider,
              let m = CGImage(maskWidth: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: gray.bytesPerRow,
                              provider: p, decode: nil, shouldInterpolate: true) else { return nil }
        masks[id] = m
        return m
    }

    func has(_ id: String) -> Bool { index[id] != nil }

    /// The glyph drawn in `color` (resolved when drawn, so it follows the theme), `height` points tall.
    func image(_ id: String, height: CGFloat, color: NSColor) -> NSImage? {
        guard let m = mask(id) else { return nil }
        let size = NSSize(width: (height * CGFloat(m.width) / CGFloat(m.height)).rounded(), height: height)
        return NSImage(size: size, flipped: false) { rect in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.interpolationQuality = .high
            c.clip(to: rect, mask: m)
            c.setFillColor(color.cgColor)
            c.fill(rect)
            return true
        }
    }
}
