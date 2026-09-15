import Foundation

struct Step {
    var index: Int
    var markerAt: Double          // audio seconds
    var imageName: String
    var jpegBase64: String
    var pixelSize: String
    var words: [Word] = []
    var startAt: Double = 0
    var endAt: Double = 0

    var narration: String {
        words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum DocBuilder {
    static let tail = 5.0        // SPEC.md §3.1 — keep recording 5s past the marker

    /// Assign every word to exactly one step by timestamp. No overlap, no dedupe,
    /// no seam artifacts — the model already saw the audio as one continuous take.
    static func assign(words: [Word], steps: inout [Step], duration: Double) -> [Word] {
        guard !steps.isEmpty else { return words }
        for i in steps.indices {
            let nextMarker = i + 1 < steps.count ? steps[i + 1].markerAt : duration
            steps[i].endAt = min(steps[i].markerAt + tail, nextMarker)
            steps[i].startAt = i == 0 ? 0 : steps[i - 1].endAt
        }
        for i in steps.indices {
            let lo = steps[i].startAt, hi = steps[i].endAt
            steps[i].words = words.filter { $0.start >= lo && $0.start < hi }
        }
        let lastEnd = steps.last!.endAt
        return words.filter { $0.start >= lastEnd }     // SPEC.md §3.4 — closing notes
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    static func title(from steps: [Step], closing: [Word]) -> String? {
        let source = steps.first?.narration ?? closing.map(\.text).joined()
        let words = source.split(separator: " ").prefix(7)
        let t = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: .punctuationCharacters)
        return t.isEmpty ? nil : t
    }

    static func human(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 60 ? "\(t / 60)m \(t % 60)s" : "\(t)s"
    }

    /// One renderer. `inlineImages` decides whether the screenshots ride along as
    /// base64 or as relative paths. No YAML, no hard wrapping — this gets pasted into
    /// chat boxes, and hard-wrapped blockquotes look like ransom notes there.
    static func render(title: String, duration: Double, steps: [Step], closing: [Word],
                       inlineImages: Bool) -> String {
        var md = "# \(title)\n\n"

        var lead = "Narrated screen recording"
        if !steps.isEmpty { lead += " — \(steps.count) step\(steps.count == 1 ? "" : "s")" }
        if duration > 0 { lead += ", \(human(duration))" }
        md += lead + ". "
        md += steps.isEmpty
            ? "No screens were captured; the narration is below.\n\n"
            : "Each step is a screenshot and what I said while looking at it, in order.\n\n"

        for s in steps {
            md += "---\n\n### Step \(s.index)\n\n"
            md += inlineImages
                ? "![Step \(s.index)](data:image/jpeg;base64,\(s.jpegBase64))\n\n"
                : "![Step \(s.index)](images/\(s.imageName))\n\n"
            let n = s.narration
            md += n.isEmpty ? "_(silent)_\n\n" : "> \(n)\n\n"
            md += "<sub>\(clock(s.startAt))–\(clock(s.endAt))</sub>\n\n"
        }

        let tail = closing.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            md += "---\n\n### \(steps.isEmpty ? "Narration" : "Closing notes")\n\n> \(tail)\n\n"
        }
        return md
    }

    /// Clipboard text flavor: NO image syntax. If an app falls back to plain text it
    /// must read like prose, not like a broken markdown file full of file paths.
    static func renderPlain(title: String, duration: Double,
                            steps: [Step], closing: [Word]) -> String {
        var t = "\(title)\n\n"
        var lead = "Narrated screen recording"
        if !steps.isEmpty { lead += " — \(steps.count) step\(steps.count == 1 ? "" : "s")" }
        if duration > 0 { lead += ", \(human(duration))" }
        t += lead + ".\n"
        for s in steps {
            t += "\nStep \(s.index)  (\(clock(s.startAt))–\(clock(s.endAt)))\n"
            let n = s.narration
            t += n.isEmpty ? "(silent)\n" : "\(n)\n"
        }
        let tail = closing.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { t += "\n\(steps.isEmpty ? "Narration" : "Closing notes")\n\(tail)\n" }
        return t
    }

    static func pad(_ n: Int) -> String { String(format: "%02d", n) }

    private static func wrap(_ text: String, at width: Int) -> [String] {
        var lines: [String] = []
        var cur = ""
        for word in text.split(separator: " ") {
            if cur.isEmpty { cur = String(word) }
            else if cur.count + 1 + word.count <= width { cur += " " + word }
            else { lines.append(cur); cur = String(word) }
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    static func sessionJSON(title: String, recorded: Date, duration: Double,
                            steps: [Step], closing: [Word]) -> Data {
        func wordObjs(_ ws: [Word]) -> [[String: Any]] {
            ws.map { ["word": $0.text, "start": $0.start, "end": $0.end,
                      "confidence": $0.confidence ?? NSNull()] }
        }
        let obj: [String: Any] = [
            "title": title,
            "startedAt": ISO8601DateFormatter().string(from: recorded),
            "durationMs": Int(duration * 1000),
            "config": ["tailMs": Int(tail * 1000), "provider": "apple-speechanalyzer",
                       "mode": "whole-file-then-slice"],
            "steps": steps.map { s in
                [
                    "index": s.index,
                    "markerAtMs": Int(s.markerAt * 1000),
                    "screenshot": "images/\(s.imageName)",
                    "pixelSize": s.pixelSize,
                    "audio": ["startMs": Int(s.startAt * 1000), "endMs": Int(s.endAt * 1000),
                              "byteStart": Int(s.startAt * AudioRecorder.bytesPerSecond),
                              "byteEnd": Int(s.endAt * AudioRecorder.bytesPerSecond)],
                    "transcript": ["text": s.narration, "words": wordObjs(s.words)],
                ]
            },
            "closingNotes": ["text": closing.map(\.text).joined()
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                             "words": wordObjs(closing)],
        ]
        return (try? JSONSerialization.data(withJSONObject: obj,
                                            options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}
