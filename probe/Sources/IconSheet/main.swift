import AppKit

let pairs: [(String, String, String)] = [
    ("text.viewfinder",              "inset.filled.rectangle.badge.record", "screen -> text. Says the product name."),
    ("rectangle.dashed.badge.record","inset.filled.rectangle.badge.record", "dashed = armed, filled = rolling. True state pair."),
    ("macwindow",                    "inset.filled.rectangle.badge.record", "plainest. a window, then a window recording."),
    ("waveform.badge.mic",           "record.circle.fill",                  "voice-forward; loses the screen half."),
    ("doc.viewfinder",               "inset.filled.rectangle.badge.record", "document-forward."),
]

func sym(_ name: String, _ pt: CGFloat, _ color: NSColor) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    guard let im = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return nil }
    im.isTemplate = false
    return im
}

let rowH: CGFloat = 190, W: CGFloat = 1180
let H = CGFloat(pairs.count) * rowH + 70
let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()

("Screen2Prompt — idle vs recording, at real menu bar size" as NSString).draw(
    at: NSPoint(x: 28, y: H - 46),
    withAttributes: [.font: NSFont.systemFont(ofSize: 21, weight: .semibold), .foregroundColor: NSColor.black])

/// Draws one menu-bar strip; returns nothing.
func strip(x: CGFloat, y: CGFloat, w: CGFloat, dark: Bool, idle: String, rec: String, scale: CGFloat) {
    let bg = dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.97, alpha: 1)
    let fg = dark ? NSColor.white : NSColor.black
    let h: CGFloat = 24 * scale
    let r = NSRect(x: x, y: y, width: w, height: h)
    bg.setFill(); r.fill()
    NSColor(white: dark ? 0.30 : 0.85, alpha: 1).setStroke(); NSBezierPath(rect: r).stroke()

    var cx = x + 14 * scale
    // idle
    if let i = sym(idle, 15 * scale, fg) {
        i.draw(in: NSRect(x: cx, y: y + (h - i.size.height)/2, width: i.size.width, height: i.size.height))
        cx += i.size.width + 34 * scale
    }
    // recording + step counter, as it appears mid-session
    if let i = sym(rec, 15 * scale, fg) {
        i.draw(in: NSRect(x: cx, y: y + (h - i.size.height)/2, width: i.size.width, height: i.size.height))
        cx += i.size.width + 5 * scale
    }
    ("3" as NSString).draw(at: NSPoint(x: cx, y: y + (h - 15*scale)/2 - 1*scale), withAttributes: [
        .font: NSFont.systemFont(ofSize: 13 * scale, weight: .regular), .foregroundColor: fg])
}

for (i, p) in pairs.enumerated() {
    let y = H - 70 - CGFloat(i + 1) * rowH
    ("\(p.0)  →  \(p.1)" as NSString).draw(at: NSPoint(x: 28, y: y + rowH - 34), withAttributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.black])
    (p.2 as NSString).draw(at: NSPoint(x: 28, y: y + rowH - 54), withAttributes: [
        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.systemGray])

    strip(x: 28,  y: y + 46, w: 150, dark: false, idle: p.0, rec: p.1, scale: 1)
    strip(x: 196, y: y + 46, w: 150, dark: true,  idle: p.0, rec: p.1, scale: 1)
    strip(x: 380, y: y + 20, w: 380, dark: false, idle: p.0, rec: p.1, scale: 2.6)
    strip(x: 782, y: y + 20, w: 380, dark: true,  idle: p.0, rec: p.1, scale: 2.6)
}
("actual size ↑                    2.6× zoom ↑" as NSString).draw(at: NSPoint(x: 28, y: 12), withAttributes: [
    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemGray])
img.unlockFocus()

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "pairs.png")
if let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
   let png = rep.representation(using: .png, properties: [:]) { try png.write(to: out); print(out.path) }
