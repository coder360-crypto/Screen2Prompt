import AppKit
import ScreenCaptureKit

enum Capture {
    struct Shot {
        let image: CGImage
        let displayID: CGDirectDisplayID
        let pointSize: CGSize
        let scale: CGFloat
        let cursor: CGPoint
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Full native-resolution grab of the display under the cursor (SPEC.md §6.1, §6.2, §6.4).
    static func displayUnderCursor() async throws -> Shot {
        let mouse = NSEvent.mouseLocation                       // Cocoa: origin bottom-left of main screen
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let screen,
              let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw S2PError("could not resolve the display under the cursor")
        }
        let displayID = CGDirectDisplayID(num.uint32Value)
        let scale = screen.backingScaleFactor

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw S2PError("display \(displayID) not offered by ScreenCaptureKit")
        }

        let cfg = SCStreamConfiguration()
        cfg.width = Int(CGFloat(display.width) * scale)          // native pixels, not points
        cfg.height = Int(CGFloat(display.height) * scale)
        cfg.captureResolution = .best
        cfg.showsCursor = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)

        // cursor in image pixel space, top-left origin
        let local = CGPoint(x: (mouse.x - screen.frame.minX) * scale,
                            y: (screen.frame.maxY - mouse.y) * scale)
        return Shot(image: image, displayID: displayID,
                    pointSize: screen.frame.size, scale: scale, cursor: local)
    }

    /// Stamp "STEP n" onto the capture itself.
    /// Once images and text are pasted separately, nothing else preserves which shot
    /// belongs to which step — attachment order is not something a chat box guarantees.
    /// A label burned into the pixels survives any amount of re-ordering.
    static func labeled(_ image: CGImage, step: Int) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let k = max(w / 1400, 1)                       // scale the badge with the capture
        let out = NSImage(size: NSSize(width: w, height: h))
        out.lockFocus()
        NSImage(cgImage: image, size: NSSize(width: w, height: h))
            .draw(in: NSRect(x: 0, y: 0, width: w, height: h))

        let text = "STEP \(step)" as NSString
        let font = NSFont.systemFont(ofSize: 22 * k, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: 1.5 * k,
        ]
        let ts = text.size(withAttributes: attrs)
        let padX = 16 * k, padY = 10 * k, dot = 7 * k, gap = 10 * k
        let bw = padX * 2 + dot * 2 + gap + ts.width
        let bh = padY * 2 + max(ts.height, dot * 2)
        let inset = 22 * k
        let badge = NSRect(x: inset, y: h - inset - bh, width: bw, height: bh)

        NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 9 * k, yRadius: 9 * k).fill()

        NSColor(srgbRed: 0xDC/255.0, green: 0x4A/255.0, blue: 0x38/255.0, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: badge.minX + padX, y: badge.midY - dot,
                                    width: dot * 2, height: dot * 2)).fill()

        text.draw(at: NSPoint(x: badge.minX + padX + dot * 2 + gap, y: badge.midY - ts.height / 2),
                  withAttributes: attrs)
        out.unlockFocus()

        guard let tiff = out.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return image }
        return cg
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw S2PError("PNG encode failed")
        }
        try data.write(to: url)
    }

    /// Downscaled JPEG for the pasteable single-file document — full res would blow up any chat box.
    static func jpegForPaste(_ image: CGImage, maxWidth: CGFloat = 1400, quality: CGFloat = 0.72) throws -> Data {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let targetW = min(w, maxWidth)
        let targetH = (h / w) * targetW
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(targetW), pixelsHigh: Int(targetH),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { throw S2PError("could not allocate resize buffer") }
        rep.size = NSSize(width: targetW, height: targetH)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: NSSize(width: w, height: h))
            .draw(in: NSRect(x: 0, y: 0, width: targetW, height: targetH))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw S2PError("JPEG encode failed")
        }
        return data
    }
}

struct S2PError: LocalizedError {
    let msg: String
    init(_ m: String) { msg = m }
    var errorDescription: String? { msg }
}
