import Foundation
import Speech
import AVFoundation
import CoreMedia

func secs(_ t: CMTime) -> String {
    t.isNumeric ? String(format: "%.2f", t.seconds) : "n/a"
}

let argv = CommandLine.arguments
guard argv.count > 1 else {
    FileHandle.standardError.write("""
    usage:
      SpeechProbe record [seconds] [locale]   record from the mic, then transcribe
      SpeechProbe <audio-file> [locale]       transcribe an existing file

    """.data(using: .utf8)!)
    exit(2)
}

let audioPath: String
let localeID: String

if argv[1] == "record" {
    let secs = argv.count > 2 ? (Double(argv[2]) ?? 15) : 15
    localeID = argv.count > 3 ? argv[3] : "en-US"
    let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("audio")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let rawURL = dir.appendingPathComponent("session.raw")
    let wavURL = dir.appendingPathComponent("mic.wav")

    print("=== RECORDING \(Int(secs))s ===")
    print("Talk now - describe whatever is on your screen, as if narrating a bug.")
    print("(If macOS asks for Microphone access, allow it; the prompt is attributed to your terminal.)\n")

    let rec = Task { try await recordMic(seconds: secs, rawURL: rawURL, wavURL: wavURL) }
    for i in stride(from: Int(secs), through: 1, by: -1) {
        print("\r  recording... \(i)s remaining   ", terminator: "")
        fflush(stdout)
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }
    print("\r  done.                            ")
    let (hw, bytes) = try await rec.value

    print("hardware input format : \(hw)")
    print("session.raw bytes     : \(bytes)")
    print("duration from bytes   : \(String(format: "%.2f", Double(bytes) / 32000.0))s   <- bytes/32000, spec 5.2")
    print("wrote                 : \(rawURL.path)")
    print("                        \(wavURL.path)\n")
    audioPath = wavURL.path
} else {
    audioPath = argv[1]
    localeID = argv.count > 2 ? argv[2] : "en-US"
}

print("=== ENVIRONMENT ===")
print("SpeechTranscriber.isAvailable : \(SpeechTranscriber.isAvailable)")
print("SFSpeechRecognizer authStatus  : \(SFSpeechRecognizer.authorizationStatus().rawValue) (0=notDetermined 1=denied 2=restricted 3=authorized)")

let supported = await SpeechTranscriber.supportedLocales
let installed = await SpeechTranscriber.installedLocales
print("supportedLocales (\(supported.count)): \(supported.map { $0.identifier(.bcp47) }.sorted().joined(separator: " "))")
print("installedLocales (\(installed.count)): \(installed.map { $0.identifier(.bcp47) }.sorted().joined(separator: " "))")
print("maximumReservedLocales        : \(AssetInventory.maximumReservedLocales)")

let requested = Locale(identifier: localeID)
let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
print("requested '\(localeID)' resolved to: \(resolved?.identifier(.bcp47) ?? "NONE")")

let transcriber = SpeechTranscriber(
    locale: resolved ?? requested,
    transcriptionOptions: [],
    reportingOptions: [],
    attributeOptions: [.audioTimeRange, .transcriptionConfidence]
)

print("\n=== ASSETS ===")
var status = await AssetInventory.status(forModules: [transcriber])
print("initial status: \(status)")
if status != .installed {
    let t0 = Date()
    if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        print("installation request returned; downloading...")
        try await req.downloadAndInstall()
        print("downloadAndInstall completed in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
    } else {
        print("assetInstallationRequest returned nil (nothing to install)")
    }
    status = await AssetInventory.status(forModules: [transcriber])
    print("post-install status: \(status)")
}

print("\n=== AUDIO ===")
let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
let audioSeconds = Double(file.length) / file.processingFormat.sampleRate
print("path      : \(audioPath)")
print("format    : \(file.processingFormat)")
print("frames    : \(file.length)  duration: \(String(format: "%.2f", audioSeconds))s")
let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
print("analyzer bestAvailableAudioFormat: \(best.map { "\($0)" } ?? "nil")")

print("\n=== TRANSCRIBE ===")
let analyzer = SpeechAnalyzer(modules: [transcriber])
let collector = Task { () -> [SpeechTranscriber.Result] in
    var out: [SpeechTranscriber.Result] = []
    for try await r in transcriber.results { out.append(r) }
    return out
}

let t0 = Date()
let lastTime = try await analyzer.analyzeSequence(from: file)
try await analyzer.finalizeAndFinishThroughEndOfInput()
let results = try await collector.value
let elapsed = Date().timeIntervalSince(t0)

print("wall clock : \(String(format: "%.2f", elapsed))s for \(String(format: "%.2f", audioSeconds))s audio  =>  \(String(format: "%.1f", audioSeconds / max(elapsed, 0.0001)))x realtime")
print("lastSampleTime: \(secs(lastTime ?? CMTime.invalid))")
print("result count : \(results.count)")

var full = AttributedString()
for (i, r) in results.enumerated() {
    print("  result[\(i)] isFinal=\(r.isFinal) range=\(secs(r.range.start))..\(secs(r.range.end)) text=\(String(r.text.characters).debugDescription)")
    full.append(r.text)
}

print("\n=== FULL TRANSCRIPT ===")
print(String(full.characters))

print("\n=== PER-RUN ATTRIBUTES ===")
var runCount = 0
var withTime = 0
var withConf = 0
for run in full.runs {
    runCount += 1
    let piece = String(full[run.range].characters)
    let tr = run.audioTimeRange
    let cf = run.transcriptionConfidence
    if tr != nil { withTime += 1 }
    if cf != nil { withConf += 1 }
    let a = tr.map { String(format: "%6.2f", $0.start.seconds) } ?? "   -  "
    let b = tr.map { String(format: "%6.2f", $0.end.seconds) } ?? "   -  "
    let c = cf.map { String(format: "%.3f", $0) } ?? "-"
    print("  [\(a) .. \(b)] conf=\(c)  \(piece.debugDescription)")
}
print("runs=\(runCount) withTimeRange=\(withTime) withConfidence=\(withConf)")
print("\n=== DONE ===")
