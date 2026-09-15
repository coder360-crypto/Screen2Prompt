import AppKit

/// Composes the whole session into ONE tall image: title, then each screenshot with its
/// narration set underneath it.
///
/// Why: a chat box asked to paste will take text OR images, never both. Two clipboard
/// items means one of them is silently dropped. One image cannot be split, cannot be
/// reordered, and cannot lose the link between a screenshot and what was said about it,
/// because they are literally the same picture.
enum Sheet {
    struct Item {
        let index: Int
        let image: NSImage
        let narration: String
        let time: String
    }

    static let width: CGFloat = 1400
    private static let margin: CGFloat = 52
    private static var content: CGFloat { width - margin * 2 }

    private static let paper  = NSColor(srgbRed: 0.980, green: 0.976, blue: 0.969, alpha: 1)
    private static let ink    = NSColor(srgbRed: 0.090, green: 0.102, blue: 0.122, alpha: 1)
    private static let quiet  = NSColor(srgbRed: 0.541, green: 0.561, blue: 0.596, alpha: 1)
    private static let marker = NSColor(srgbRed: 0.863, green: 0.290, blue: 0.220, alpha: 1)
    private static let hair   = NSColor(srgbRed: 0.894, green: 0.882, blue: 0.863, alpha: 1)

    private static func attrs(_ size: CGFloat, _ weight: NSFont.Weight,
                              _ color: NSColor, lineHeight: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        if lineHeight > 0 { p.lineSpacing = lineHeight }
        return [.font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color, .paragraphStyle: p]
    }

    private static func height(_ s: String, _ a: [NSAttributedString.Key: Any]) -> CGFloat {
        guard !s.isEmpty else { return 0 }
        return ceil(NSAttributedString(string: s, attributes: a)
            .boundingRect(with: NSSize(width: content, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    static func compose(title: String, summary: String, items: [Item], closing: String) -> NSImage {
        let titleA   = attrs(36, .semibold, ink)
        let summaryA = attrs(16, .regular, quiet, lineHeight: 4)
        let headA    = attrs(21, .semibold, ink)
        let timeA    = attrs(14, .medium, quiet)
        let bodyA    = attrs(19, .regular, ink, lineHeight: 7)
        let footA    = attrs(13, .regular, quiet)

        // ---- measure ----
        var total = margin
        total += height(title, titleA) + 14
        total += height(summary, summaryA) + 34

        var shotHeights: [CGFloat] = []
        for it in items {
            let s = it.image.size
            let h = s.width > 0 ? (content * s.height / s.width) : 0
            shotHeights.append(h)
            total += 30 + 14 + h + 18 + height(it.narration.isEmpty ? "(silent)" : it.narration, bodyA) + 44
        }
        if !closing.isEmpty {
            total += 30 + 14 + height(closing, bodyA) + 30
        }
        total += 28 + margin
        let H = ceil(total)

        // ---- draw ----
        let img = NSImage(size: NSSize(width: width, height: H))
        img.lockFocus()
        paper.setFill()
        NSRect(x: 0, y: 0, width: width, height: H).fill()

        var y = margin                                  // distance from the TOP
        func put(_ s: String, _ a: [NSAttributedString.Key: Any], _ h: CGFloat, x: CGFloat = margin) {
            guard !s.isEmpty else { return }
            NSAttributedString(string: s, attributes: a)
                .draw(with: NSRect(x: x, y: H - y - h, width: content, height: h),
                      options: [.usesLineFragmentOrigin, .usesFontLeading])
        }

        let th = height(title, titleA); put(title, titleA, th); y += th + 14
        let sh = height(summary, summaryA); put(summary, summaryA, sh); y += sh + 34

        for (i, it) in items.enumerated() {
            // rule
            hair.setFill(); NSRect(x: margin, y: H - y, width: content, height: 1).fill()
            y += 22

            // "Step n" with the marker dot, and the timing on the right
            marker.setFill()
            NSBezierPath(ovalIn: NSRect(x: margin, y: H - y - 16, width: 9, height: 9)).fill()
            let head = "Step \(it.index)"
            NSAttributedString(string: head, attributes: headA)
                .draw(at: NSPoint(x: margin + 19, y: H - y - 22))
            let t = NSAttributedString(string: it.time, attributes: timeA)
            t.draw(at: NSPoint(x: width - margin - ceil(t.size().width), y: H - y - 19))
            y += 30 + 14

            // the screenshot, already carrying its burned-in STEP badge
            let h = shotHeights[i]
            let r = NSRect(x: margin, y: H - y - h, width: content, height: h)
            it.image.draw(in: r)
            hair.setStroke(); NSBezierPath(rect: r).stroke()
            y += h + 18

            let body = it.narration.isEmpty ? "(silent)" : it.narration
            let bh = height(body, bodyA); put(body, bodyA, bh); y += bh + 44
        }

        if !closing.isEmpty {
            hair.setFill(); NSRect(x: margin, y: H - y, width: content, height: 1).fill()
            y += 22
            NSAttributedString(string: "Closing notes", attributes: headA)
                .draw(at: NSPoint(x: margin, y: H - y - 22))
            y += 30 + 14
            let ch = height(closing, bodyA); put(closing, bodyA, ch); y += ch + 30
        }

        put("Screen2Prompt", footA, 18)
        img.unlockFocus()
        return img
    }

    /// ONE CARD PER STEP: the screenshot with that step's narration set underneath it.
    /// Pasted as N attachments, which is what chat boxes actually handle well — and each
    /// card is self-contained, so the words can never be separated from their picture.
    static func card(item: Item, of total: Int, title: String?) -> NSImage {
        let crumbA = attrs(14, .medium, quiet)
        let headA  = attrs(23, .semibold, ink)
        let timeA  = attrs(15, .medium, quiet)
        let bodyA  = attrs(20, .regular, ink, lineHeight: 7)

        let crumb = title.map { "\($0)  ·  step \(item.index) of \(total)" }
            ?? "Step \(item.index) of \(total)"
        let body = item.narration.isEmpty ? "(silent)" : item.narration

        let shotH = item.image.size.width > 0
            ? content * item.image.size.height / item.image.size.width : 0
        let crumbH = height(crumb, crumbA)
        let bodyH  = height(body, bodyA)
        let H = ceil(margin + crumbH + 10 + 32 + 16 + shotH + 22 + bodyH + margin)

        let img = NSImage(size: NSSize(width: width, height: H))
        img.lockFocus()
        paper.setFill(); NSRect(x: 0, y: 0, width: width, height: H).fill()

        var y = margin
        NSAttributedString(string: crumb, attributes: crumbA)
            .draw(with: NSRect(x: margin, y: H - y - crumbH, width: content, height: crumbH),
                  options: [.usesLineFragmentOrigin])
        y += crumbH + 10

        marker.setFill()
        NSBezierPath(ovalIn: NSRect(x: margin, y: H - y - 19, width: 11, height: 11)).fill()
        NSAttributedString(string: "Step \(item.index)", attributes: headA)
            .draw(at: NSPoint(x: margin + 22, y: H - y - 25))
        let t = NSAttributedString(string: item.time, attributes: timeA)
        t.draw(at: NSPoint(x: width - margin - ceil(t.size().width), y: H - y - 23))
        y += 32 + 16

        let r = NSRect(x: margin, y: H - y - shotH, width: content, height: shotH)
        item.image.draw(in: r)
        hair.setStroke(); NSBezierPath(rect: r).stroke()
        y += shotH + 22

        NSAttributedString(string: body, attributes: bodyA)
            .draw(with: NSRect(x: margin, y: H - y - bodyH, width: content, height: bodyH),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        img.unlockFocus()
        return img
    }

    /// A text-only card, for closing notes that belong to no screenshot.
    static func textCard(title: String, body: String) -> NSImage {
        let headA = attrs(23, .semibold, ink)
        let bodyA = attrs(20, .regular, ink, lineHeight: 7)
        let bh = height(body, bodyA)
        let H = ceil(margin + 30 + 18 + bh + margin)
        let img = NSImage(size: NSSize(width: width, height: H))
        img.lockFocus()
        paper.setFill(); NSRect(x: 0, y: 0, width: width, height: H).fill()
        NSAttributedString(string: title, attributes: headA).draw(at: NSPoint(x: margin, y: H - margin - 26))
        NSAttributedString(string: body, attributes: bodyA)
            .draw(with: NSRect(x: margin, y: H - margin - 30 - 18 - bh, width: content, height: bh),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        img.unlockFocus()
        return img
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Same sheet, a tenth of the bytes. Screenshots are photographic, so PNG is a poor
    /// fit; some chat boxes reject or stall on a 9 MB paste.
    static func jpeg(_ image: NSImage, quality: CGFloat = 0.82) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
