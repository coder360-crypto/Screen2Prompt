import Foundation
import AVFoundation

/// Mic -> downmix -> 16 kHz mono Int16 -> session.raw  (SPEC.md §5.1, §5.2)
/// Byte offsets ARE timestamps: bytesPerSecond = 16000 * 2 = 32000.
final class RawWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var _bytes = 0
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return _bytes }

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }
    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        handle.write(d); _bytes += d.count
    }
    func close() { try? handle.close() }
}

final class AudioRecorder {
    static let bytesPerSecond = 32000.0

    private let engine = AVAudioEngine()
    private var writer: RawWriter?
    private(set) var running = false
    private(set) var hardwareFormat = ""

    /// Seconds of audio captured so far, derived from bytes written — exact, no wall clock drift.
    var elapsedSeconds: Double { Double(writer?.bytes ?? 0) / Self.bytesPerSecond }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(rawURL: URL) throws {
        guard !running else { return }
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0 else { throw S2PError("no microphone input available") }
        hardwareFormat = "\(Int(hw.sampleRate)) Hz, \(hw.channelCount) ch"

        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: hw, to: target) else {
            throw S2PError("could not build a 16 kHz mono converter from \(hw)")
        }

        let w = try RawWriter(url: rawURL)
        writer = w
        let ratio = target.sampleRate / hw.sampleRate

        input.installTap(onBus: 0, bufferSize: 4096, format: hw) { buffer, _ in
            let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 4096
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            var err: NSError?
            var fed = false
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard err == nil, let ch = out.int16ChannelData, out.frameLength > 0 else { return }
            w.append(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
        }

        engine.prepare()
        try engine.start()
        running = true
    }

    /// Stops and writes a WAV alongside the raw file. Returns audio duration in seconds.
    @discardableResult
    func stop(wavURL: URL, rawURL: URL) throws -> Double {
        guard running else { return 0 }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.close()
        running = false

        let pcm = try Data(contentsOf: rawURL)
        var wav = Self.wavHeader(pcmLen: UInt32(pcm.count))
        wav.append(pcm)
        try wav.write(to: wavURL)
        return Double(pcm.count) / Self.bytesPerSecond
    }

    /// SPEC.md §5.3 — 44 bytes, by hand. No ffmpeg anywhere in this project.
    static func wavHeader(pcmLen: UInt32, sampleRate: UInt32 = 16000) -> Data {
        var h = Data(capacity: 44)
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        h.append(contentsOf: Array("RIFF".utf8)); le32(36 + pcmLen)
        h.append(contentsOf: Array("WAVE".utf8))
        h.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)
        le32(sampleRate); le32(sampleRate * 2); le16(2); le16(16)
        h.append(contentsOf: Array("data".utf8)); le32(pcmLen)
        return h
    }
}
