import AppKit

/// The "Signal" menu bar glyph — corner brackets framing a region, with the amber
/// cursor block as the recording marker. Terminal-native, square caps, hard corners.
///
/// Idle  : brackets only            (armed, nothing rolling)
/// Live  : brackets + amber block   (recording)
/// Flash : + a halo, ~180ms after a capture
enum Glyph {
    static let amber = NSColor(srgbRed: 0xE9/255.0, green: 0xA1/255.0, blue: 0x3B/255.0, alpha: 1)

    static func image(recording: Bool, flash: Bool, tint: NSColor, size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = size / 16.0
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size)
            ctx.scaleBy(x: s, y: -s)

            // four corner brackets
            ctx.setStrokeColor(tint.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineCap(.square)
            ctx.setLineJoin(.miter)
            let p = CGMutablePath()
            let a: CGFloat = 1.6, b: CGFloat = 14.4, arm: CGFloat = 3.6
            p.move(to: CGPoint(x: a, y: a + arm));  p.addLine(to: CGPoint(x: a, y: a));  p.addLine(to: CGPoint(x: a + arm, y: a))
            p.move(to: CGPoint(x: b - arm, y: a));  p.addLine(to: CGPoint(x: b, y: a));  p.addLine(to: CGPoint(x: b, y: a + arm))
            p.move(to: CGPoint(x: a, y: b - arm));  p.addLine(to: CGPoint(x: a, y: b));  p.addLine(to: CGPoint(x: a + arm, y: b))
            p.move(to: CGPoint(x: b - arm, y: b));  p.addLine(to: CGPoint(x: b, y: b));  p.addLine(to: CGPoint(x: b, y: b - arm))
            ctx.addPath(p)
            ctx.strokePath()

            if recording {
                if flash {
                    ctx.setStrokeColor(amber.withAlphaComponent(0.5).cgColor)
                    ctx.setLineWidth(1.1)
                    ctx.stroke(CGRect(x: 4.4, y: 4.4, width: 7.2, height: 7.2))
                }
                ctx.setFillColor(amber.cgColor)
                ctx.fill(CGRect(x: 6.1, y: 5.6, width: 3.8, height: 4.8))
            } else {
                // a quiet centre bar so idle does not read as an empty frame
                ctx.setStrokeColor(tint.withAlphaComponent(0.55).cgColor)
                ctx.setLineWidth(1.5)
                ctx.move(to: CGPoint(x: 8, y: 5.8)); ctx.addLine(to: CGPoint(x: 8, y: 10.2))
                ctx.strokePath()
            }
            ctx.restoreGState()
            return true
        }
        img.isTemplate = !recording      // idle is monochrome; let AppKit invert it
        return img
    }

    /// Larger mark for the app icon / about box, on a dark ground.
    static func mark(size: CGFloat, tint: NSColor = .white) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = size / 48.0
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size)
            ctx.scaleBy(x: s, y: -s)
            ctx.setStrokeColor(tint.cgColor)
            ctx.setLineWidth(2.9)
            ctx.setLineCap(.square)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 6, y: 15)); p.addLine(to: CGPoint(x: 6, y: 6));  p.addLine(to: CGPoint(x: 15, y: 6))
            p.move(to: CGPoint(x: 33, y: 6)); p.addLine(to: CGPoint(x: 42, y: 6)); p.addLine(to: CGPoint(x: 42, y: 15))
            p.move(to: CGPoint(x: 6, y: 33)); p.addLine(to: CGPoint(x: 6, y: 42)); p.addLine(to: CGPoint(x: 15, y: 42))
            p.move(to: CGPoint(x: 42, y: 33)); p.addLine(to: CGPoint(x: 42, y: 42)); p.addLine(to: CGPoint(x: 33, y: 42))
            ctx.addPath(p); ctx.strokePath()
            // waveform
            ctx.setLineWidth(2.9)
            ctx.move(to: CGPoint(x: 15, y: 20)); ctx.addLine(to: CGPoint(x: 15, y: 28))
            ctx.move(to: CGPoint(x: 20, y: 14.5)); ctx.addLine(to: CGPoint(x: 20, y: 33.5))
            ctx.move(to: CGPoint(x: 25, y: 22)); ctx.addLine(to: CGPoint(x: 25, y: 26))
            ctx.strokePath()
            // cursor block
            ctx.setFillColor(amber.cgColor)
            ctx.fill(CGRect(x: 30, y: 20, width: 7.5, height: 8))
            ctx.restoreGState()
            return true
        }
        return img
    }
}
