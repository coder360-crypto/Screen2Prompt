import Foundation
import Speech
import AVFoundation
import CoreMedia

struct Word {
    let text: String        // carries its own leading space, as the model emits it
    let start: Double
    let end: Double
    let confidence: Double?
}

enum Transcribe {
    /// One pass over the whole session. Because this runs at 30-60x realtime on-device,
    /// there is no reason to chunk during recording: transcribe once, then slice the
    /// words into steps by timestamp. That removes SPEC.md §3.3 (overlap, dedupe,
    /// prompt continuity) and is MORE accurate, since the model sees continuous audio.
    static func wholeFile(_ url: URL, localeID: String = "en-US") async throws -> [Word] {
        guard SpeechTranscriber.isAvailable else {
            throw S2PError("on-device transcription is not available on this Mac")
        }
        let requested = Locale(identifier: localeID)
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) ?? requested

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )

        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await req.downloadAndInstall()
            }
        }

        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [SpeechTranscriber.Result] in
            var out: [SpeechTranscriber.Result] = []
            for try await r in transcriber.results { out.append(r) }
            return out
        }
        _ = try await analyzer.analyzeSequence(from: file)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let results = try await collector.value

        var joined = AttributedString()
        for r in results { joined.append(r.text) }

        var words: [Word] = []
        for run in joined.runs {
            let piece = String(joined[run.range].characters)
            if piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let range = run.audioTimeRange else { continue }
            words.append(Word(text: piece,
                              start: range.start.seconds,
                              end: range.end.seconds,
                              confidence: run.transcriptionConfidence))
        }
        return words
    }
}
