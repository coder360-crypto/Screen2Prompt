import Foundation

/// Everything downstream — chunking, step assignment, the document — depends only on
/// this. Swapping the engine cannot leak into the rest of the app.
protocol Transcriber {
    var name: String { get }
    func transcribe(wav: URL) async throws -> [Word]
}

// MARK: - Apple, on-device (default)

struct AppleTranscriber: Transcriber {
    let locale: String
    var name: String { "Apple SpeechAnalyzer (\(locale), on-device)" }
    func transcribe(wav: URL) async throws -> [Word] {
        try await Transcribe.wholeFile(wav, localeID: locale)
    }
}

// MARK: - Groq Whisper

/// For languages Apple has no on-device model for — Hindi and code-switched speech
/// being the reason this exists at all. Needs a key and a network.
struct GroqTranscriber: Transcriber {
    let model: String
    let language: String?
    var name: String { "Groq \(model)" }

    func transcribe(wav: URL) async throws -> [Word] {
        guard let key = Keychain.groqKey(), !key.isEmpty else {
            throw S2PError("No Groq API key. Run: Screen2Prompt --set-groq-key, or set GROQ_API_KEY.")
        }
        let boundary = "s2p-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"session.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: wav))
        body.append("\r\n".data(using: .utf8)!)
        field("model", model)
        field("response_format", "verbose_json")
        field("timestamp_granularities[]", "word")
        field("temperature", "0")
        if let language { field("language", language) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw S2PError("Groq: no response") }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "\(http.statusCode)"
            throw S2PError("Groq \(http.statusCode): \(msg.prefix(300))")
        }
        struct R: Decodable {
            struct W: Decodable { let word: String; let start: Double; let end: Double }
            let words: [W]?
            let text: String?
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        if let ws = r.words, !ws.isEmpty {
            return ws.map { Word(text: " " + $0.word, start: $0.start, end: $0.end, confidence: nil) }
        }
        // no word timings came back: one block, attributed to the first step
        return [Word(text: r.text ?? "", start: 0, end: 0, confidence: nil)]
    }
}

// MARK: - Local whisper.cpp

/// Fully offline, no caps, works on a plane. Point `whisperBinary` and `whisperModel`
/// at a whisper.cpp build in ~/.screen2prompt/config.json.
struct WhisperCppTranscriber: Transcriber {
    let binary: String
    let model: String
    var name: String { "whisper.cpp (\((model as NSString).lastPathComponent))" }

    func transcribe(wav: URL) async throws -> [Word] {
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw S2PError("whisper binary not found at \(binary) — set whisperBinary in ~/.screen2prompt/config.json")
        }
        guard !model.isEmpty, FileManager.default.fileExists(atPath: model) else {
            throw S2PError("whisper model not found at \(model) — set whisperModel in ~/.screen2prompt/config.json")
        }
        let out = wav.deletingPathExtension()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-m", model, "-f", wav.path, "-oj", "-of", out.path, "-ml", "1", "-np"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw S2PError("whisper.cpp exited \(p.terminationStatus)")
        }
        let jsonURL = out.appendingPathExtension("json")
        let data = try Data(contentsOf: jsonURL)
        struct R: Decodable {
            struct Seg: Decodable {
                struct Offsets: Decodable { let from: Int; let to: Int }
                let text: String
                let offsets: Offsets
            }
            let transcription: [Seg]
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        return r.transcription.map {
            Word(text: $0.text, start: Double($0.offsets.from) / 1000,
                 end: Double($0.offsets.to) / 1000, confidence: nil)
        }
    }
}

// MARK: - Selection

enum Transcribers {
    static func make(_ c: Config) -> Transcriber {
        switch c.provider.lowercased() {
        case "groq":
            return GroqTranscriber(model: c.groqModel,
                                   language: c.locale.hasPrefix("auto") ? nil : String(c.locale.prefix(2)))
        case "whisper", "whispercpp", "local":
            return WhisperCppTranscriber(binary: c.whisperBinary, model: c.whisperModel)
        default:
            return AppleTranscriber(locale: c.locale)
        }
    }
}
