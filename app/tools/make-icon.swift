import AppKit

// Renders AppIcon.icns from the Signal mark. Run: swift tools/make-icon.swift <outdir>
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let amber = NSColor(srgbRed: 0xE9/255.0, green: 0xA1/255.0, blue: 0x3B/255.0, alpha: 1)
let fg    = NSColor(srgbRed: 0xE7/255.0, green: 0xE4/255.0, blue: 0xDA/255.0, alpha: 1)

func icon(_ px: CGFloat) -> Data {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = px * 0.085                        // macOS icons sit in a safe area
    let r = NSRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    let squircle = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)

    ctx.saveGState(); squircle.addClip()
    let grad = NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.17, blue: 0.14, alpha: 1),
                                   NSColor(srgbRed: 0.055, green: 0.06, blue: 0.05, alpha: 1)])!
    grad.draw(in: r, angle: -90)
    ctx.restoreGState()

    // the mark, on a 48 grid centred in the squircle
    let s = r.width / 48 * 0.62
    ctx.saveGState()
    ctx.translateBy(x: r.midX - 24 * s, y: r.midY - 24 * s)
    ctx.scaleBy(x: s, y: s)
    ctx.setStrokeColor(fg.cgColor)
    ctx.setLineWidth(3.0)
    ctx.setLineCap(.square)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 6, y: 33));  p.addLine(to: CGPoint(x: 6, y: 42));  p.addLine(to: CGPoint(x: 15, y: 42))
    p.move(to: CGPoint(x: 33, y: 42)); p.addLine(to: CGPoint(x: 42, y: 42)); p.addLine(to: CGPoint(x: 42, y: 33))
    p.move(to: CGPoint(x: 6, y: 15));  p.addLine(to: CGPoint(x: 6, y: 6));   p.addLine(to: CGPoint(x: 15, y: 6))
    p.move(to: CGPoint(x: 33, y: 6));  p.addLine(to: CGPoint(x: 42, y: 6));  p.addLine(to: CGPoint(x: 42, y: 15))
    ctx.addPath(p); ctx.strokePath()
    ctx.move(to: CGPoint(x: 15, y: 20)); ctx.addLine(to: CGPoint(x: 15, y: 28))
    ctx.move(to: CGPoint(x: 20, y: 14.5)); ctx.addLine(to: CGPoint(x: 20, y: 33.5))
    ctx.move(to: CGPoint(x: 25, y: 22)); ctx.addLine(to: CGPoint(x: 25, y: 26))
    ctx.strokePath()
    ctx.setFillColor(amber.cgColor)
    ctx.fill(CGRect(x: 30, y: 20, width: 7.5, height: 8))
    ctx.restoreGState()

    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let set = "\(out)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16.0), ("16x16@2x", 32.0), ("32x32", 32.0), ("32x32@2x", 64.0),
                   ("128x128", 128.0), ("128x128@2x", 256.0), ("256x256", 256.0),
                   ("256x256@2x", 512.0), ("512x512", 512.0), ("512x512@2x", 1024.0)] {
    try! icon(px).write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
try! icon(1024).write(to: URL(fileURLWithPath: "\(out)/icon-1024.png"))
print("iconset written to \(set)")
