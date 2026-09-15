import AppKit

/// One pasteboard ITEM carrying several flavors, richest first.
/// The receiving app picks what it understands:
///   RTFD  -> Notes, Mail, Slack, TextEdit   : text with real inline images
///   HTML  -> web chat inputs (contenteditable): text with base64 <img> inline
///   plain -> anything else                  : the markdown
/// This is the only way one Cmd-V delivers words AND pictures. Separate file items
/// do not work: apps that see files attach them and discard the text entirely.
enum Clipboard {
    static func writeDocument(title: String, summary: String,
                              steps: [(index: Int, jpeg: Data, narration: String, time: String)],
                              closing: String,
                              markdown: String) {
        let item = NSPasteboardItem()

        if let rtfd = makeRTFD(title: title, summary: summary, steps: steps, closing: closing) {
            item.setData(rtfd, forType: .rtfd)
        }
        item.setString(makeHTML(title: title, summary: summary, steps: steps, closing: closing),
                       forType: .html)
        item.setString(markdown, forType: .string)

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }

    // MARK: HTML

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func makeHTML(title: String, summary: String,
                                 steps: [(index: Int, jpeg: Data, narration: String, time: String)],
                                 closing: String) -> String {
        var h = "<meta charset=\"utf-8\">"
        h += "<div style=\"font-family:-apple-system,BlinkMacSystemFont,sans-serif;line-height:1.5\">"
        h += "<h2>\(esc(title))</h2><p>\(esc(summary))</p>"
        for s in steps {
            h += "<h3>Step \(s.index)</h3>"
            h += "<img src=\"data:image/jpeg;base64,\(s.jpeg.base64EncodedString())\" "
            h += "style=\"max-width:100%;height:auto\" alt=\"Step \(s.index)\"><br>"
            if !s.narration.isEmpty {
                h += "<blockquote style=\"margin:8px 0;padding-left:12px;"
                h += "border-left:3px solid #ccc\">\(esc(s.narration))</blockquote>"
            }
            h += "<p style=\"color:#888;font-size:12px\">\(esc(s.time))</p>"
        }
        if !closing.isEmpty {
            h += "<h3>Closing notes</h3><blockquote style=\"margin:8px 0;padding-left:12px;"
            h += "border-left:3px solid #ccc\">\(esc(closing))</blockquote>"
        }
        return h + "</div>"
    }

    // MARK: RTFD (real image attachments)

    private static func makeRTFD(title: String, summary: String,
                                 steps: [(index: Int, jpeg: Data, narration: String, time: String)],
                                 closing: String) -> Data? {
        let out = NSMutableAttributedString()
        func add(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .textColor) {
            out.append(NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
            ]))
        }
        add(title + "\n", size: 20, weight: .semibold)
        add(summary + "\n\n", size: 13, color: .secondaryLabelColor)

        for s in steps {
            add("Step \(s.index)\n", size: 15, weight: .semibold)
            if let img = NSImage(data: s.jpeg) {
                // keep attachments to a sane on-screen width
                let maxW: CGFloat = 560
                let scale = min(1, maxW / max(img.size.width, 1))
                img.size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
                let att = NSTextAttachment()
                att.image = img
                out.append(NSAttributedString(attachment: att))
                out.append(NSAttributedString(string: "\n"))
            }
            if !s.narration.isEmpty { add(s.narration + "\n", size: 13) }
            add(s.time + "\n\n", size: 11, color: .tertiaryLabelColor)
        }
        if !closing.isEmpty {
            add("Closing notes\n", size: 15, weight: .semibold)
            add(closing + "\n", size: 13)
        }
        return out.rtfd(from: NSRange(location: 0, length: out.length),
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }
}
