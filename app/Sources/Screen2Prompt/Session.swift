import AppKit

@MainActor
final class Session {
    enum State { case idle, recording, finishing }

    private(set) var state: State = .idle
    private(set) var markerCount = 0
    private(set) var startedAt: Date?
    private(set) var lastDocument: String?
    private(set) var lastFolder: URL?
    private(set) var lastError: String?

    var onChange: (@MainActor () -> Void)?
    var onFinished: (@MainActor (_ folder: URL, _ steps: Int, _ chars: Int) -> Void)?
    var onFailure: (@MainActor (String) -> Void)?

    private let audio = AudioRecorder()
    private var folder: URL?
    private var steps: [Step] = []
    private var audioOK = false
    private(set) var captureFailures = 0
    var config = Config.load()
    private var builtSteps: [Step] = []
    private var lastTitle: String?
    private var lastSummary: String?
    private var lastClosing: String?
    private var lastClosingWords: [Word] = []
    private var lastDuration: Double = 0

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Screen2Prompt")
    }

    // MARK: start

    func start() async {
        guard state == .idle else { return }
        lastError = nil
        steps = []
        markerCount = 0
        captureFailures = 0
        startedAt = Date()

        let stamp = Self.stampFormatter.string(from: startedAt!)
        let dir = Self.root.appendingPathComponent(stamp)
        do {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("images"),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("audio"),
                                                    withIntermediateDirectories: true)
        } catch {
            fail("could not create \(dir.path): \(error.localizedDescription)"); return
        }
        folder = dir

        // SPEC.md §9 case 7: no microphone must not cost you the screenshots.
        audioOK = await AudioRecorder.requestPermission()
        if audioOK {
            do { try audio.start(rawURL: dir.appendingPathComponent("audio/session.raw")) }
            catch { audioOK = false; lastError = "audio unavailable: \(error.localizedDescription)" }
        } else {
            lastError = "microphone permission denied — capturing screens only"
        }

        state = .recording
        Log.write("session: started dir=\(dir.lastPathComponent) audioOK=\(audioOK) screenPerm=\(Capture.hasPermission)")
        onChange?()
    }

    // MARK: marker

    func mark() async {
        guard state == .recording, let dir = folder else { return }
        let at = audio.elapsedSeconds                    // press moment, before any await
        Log.write("mark: begin index=\(steps.count + 1) at=\(String(format: "%.2f", at))s screenPerm=\(Capture.hasPermission)")
        let index = steps.count + 1
        let name = "step-\(DocBuilder.pad(index)).png"

        do {
            let shot = try await Capture.displayUnderCursor()
            let stamped = Capture.labeled(shot.image, step: index)
            try Capture.writePNG(stamped, to: dir.appendingPathComponent("images/\(name)"))
            let jpeg = try Capture.jpegForPaste(stamped)
            steps.append(Step(index: index, markerAt: at, imageName: name,
                              jpegBase64: jpeg.base64EncodedString(),
                              pixelSize: "\(shot.image.width)×\(shot.image.height)"))
            markerCount = steps.count
            Log.write("mark: OK \(name) \(shot.image.width)x\(shot.image.height)")
            onChange?()
        } catch {
            captureFailures += 1
            Log.write("mark: FAILED \(error)")
            fail("screen capture failed: \(error.localizedDescription)")
        }
    }

    // MARK: stop

    func stop() async {
        guard state == .recording, let dir = folder, let began = startedAt else { return }
        state = .finishing
        onChange?()

        var duration = 0.0
        let rawURL = dir.appendingPathComponent("audio/session.raw")
        let wavURL = dir.appendingPathComponent("audio/session.wav")
        if audioOK {
            duration = (try? audio.stop(wavURL: wavURL, rawURL: rawURL)) ?? 0
        }

        var words: [Word] = []
        if audioOK, duration > 0.4 {
            let engine = Transcribers.make(config)
            Log.write("transcribe: \(engine.name)")
            do { words = try await engine.transcribe(wav: wavURL) }
            catch {
                lastError = "transcription failed: \(error.localizedDescription)"
                Log.write("transcribe: FAILED \(error)")
            }
        }

        var built = steps
        let closing = DocBuilder.assign(words: words, steps: &built, duration: max(duration, 0))
        let auto = DocBuilder.title(from: built, closing: closing)
        let title = auto ?? "Screen recording \(Self.stampFormatter.string(from: began))"

        let paste = DocBuilder.render(title: title, duration: duration,
                                      steps: built, closing: closing, inlineImages: true)
        let doc = DocBuilder.render(title: title, duration: duration,
                                    steps: built, closing: closing, inlineImages: false)
        let json = DocBuilder.sessionJSON(title: title, recorded: began,
                                          duration: duration, steps: built, closing: closing)

        try? paste.write(to: dir.appendingPathComponent("PROMPT.md"), atomically: true, encoding: .utf8)
        try? doc.write(to: dir.appendingPathComponent("doc.md"), atomically: true, encoding: .utf8)
        try? json.write(to: dir.appendingPathComponent("session.json"))
        // plain transcript, so the Recent menu can hand it back later without re-parsing
        let transcript = DocBuilder.renderPlain(title: title, duration: duration,
                                                steps: built, closing: closing)
        try? transcript.write(to: dir.appendingPathComponent("transcript.txt"),
                              atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: rawURL)      // SPEC.md §5.2

        // Rename the folder to carry the title, now that we know it.
        var final = dir
        let slug = auto.map(Self.slug) ?? ""
        if !slug.isEmpty {
            let renamed = dir.deletingLastPathComponent()
                .appendingPathComponent(dir.lastPathComponent + "_" + slug)
            if (try? FileManager.default.moveItem(at: dir, to: renamed)) != nil { final = renamed }
        }

        builtSteps = built
        lastClosingWords = closing
        lastDuration = duration
        lastTitle = title
        lastSummary = "Narrated screen recording — \(built.count) step\(built.count == 1 ? "" : "s"), \(DocBuilder.human(duration)). Each step is a screenshot and what I said while looking at it, in order."
        lastClosing = closing.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        lastDocument = paste
        lastFolder = final
        copyForPaste()
        state = .idle
        startedAt = nil
        onChange?()
        Log.write("session: done steps=\(built.count) closingWords=\(closing.count) dur=\(String(format: "%.1f", duration))s dir=\(final.lastPathComponent)")
        onFinished?(final, built.count, paste.count)
    }

    /// One Cmd-V -> N attachments, one per step, each carrying its own narration.
    /// Chat boxes take images OR text from a paste, never both, so the words live
    /// inside the pictures. Plain text rides on the first item for anything that
    /// prefers text.
    func copyForPaste() {
        guard let dir = lastFolder ?? folder else { return }
        let total = builtSteps.count
        var cards: [NSImage] = []
        for st in builtSteps {
            guard let data = Data(base64Encoded: st.jpegBase64),
                  let img = NSImage(data: data) else { continue }
            let it = Sheet.Item(index: st.index, image: img, narration: st.narration,
                                time: "\(DocBuilder.clock(st.startAt))–\(DocBuilder.clock(st.endAt))")
            cards.append(Sheet.card(item: it, of: total, title: lastTitle))
        }
        if let tail = lastClosing, !tail.isEmpty {
            cards.append(Sheet.textCard(title: "Closing notes", body: tail))
        }

        let plain = DocBuilder.renderPlain(title: lastTitle ?? "Screen recording",
                                           duration: lastDuration, steps: builtSteps,
                                           closing: lastClosingWords)

        let pb = NSPasteboard.general
        pb.clearContents()
        guard !cards.isEmpty else { pb.setString(plain, forType: .string); return }

        // FILE URLs, not image data. Apps treat several files as several attachments;
        // several raw image items collapse to just the first one. Losing the text
        // flavor costs nothing now — every card already has its narration drawn in.
        var urls: [NSURL] = []
        var bytes = 0
        for (i, card) in cards.enumerated() {
            // JPEG, not PNG: a card is mostly screenshot, so PNG is ~6x the bytes for no
            // visible gain — and the upload time is what you actually feel.
            guard let data = Sheet.jpeg(card, quality: 0.85) else { continue }
            let url = dir.appendingPathComponent("step-\(DocBuilder.pad(i + 1)).jpg")
            do {
                try data.write(to: url)
                urls.append(url as NSURL)
                bytes += data.count
            } catch {
                Log.write("clipboard: could not write \(url.lastPathComponent): \(error)")
            }
        }
        guard !urls.isEmpty else { pb.setString(plain, forType: .string); return }
        pb.writeObjects(urls)
        Log.write("clipboard: \(urls.count) card files, \(bytes / 1024) KB")
    }

    /// The narration as plain text, for when you want the words rather than the cards.
    func copyTextOnly() {
        let plain = DocBuilder.renderPlain(title: lastTitle ?? "Screen recording",
                                           duration: lastDuration, steps: builtSteps,
                                           closing: lastClosingWords)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(plain, forType: .string)
    }

    /// Screenshots only — for a chat that wants them as separate attachments.
    func copyImagesOnly() {
        guard let dir = lastFolder ?? folder else { return }
        let urls = steps.map { dir.appendingPathComponent("images/\($0.imageName)") as NSURL }
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls)
    }

    private func copyToClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    var elapsed: Double { audio.running ? audio.elapsedSeconds : 0 }

    private func fail(_ m: String) {
        lastError = m
        onFailure?(m)
        onChange?()
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    static func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -"))
        let cleaned = s.unicodeScalars.filter { allowed.contains($0) }.map(Character.init)
        return String(cleaned).lowercased()
            .split(separator: " ").prefix(5).joined(separator: "-")
    }
}
