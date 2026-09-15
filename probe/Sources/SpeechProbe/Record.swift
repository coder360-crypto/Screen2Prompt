import Foundation
import AVFoundation

// Spec 5.3 — 44-byte WAV header, written by hand. No ffmpeg anywhere.
func wavHeader(pcmLen: UInt32, sampleRate: UInt32 = 16000) -> Data {
    var h = Data(capacity: 44)
    func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
    func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
    h.append(contentsOf: Array("RIFF".utf8));  le32(36 + pcmLen)
    h.append(contentsOf: Array("WAVE".utf8))
    h.append(contentsOf: Array("fmt ".utf8));  le32(16); le16(1); le16(1)
    le32(sampleRate); le32(sampleRate * 2); le16(2); le16(16)
    h.append(contentsOf: Array("data".utf8));  le32(pcmLen)
    return h
}

final class RawWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private(set) var bytesWritten = 0
    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }
    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        handle.write(d); bytesWritten += d.count
    }
    func close() { try? handle.close() }
}

/// Capture mic -> downmix -> resample to 16 kHz mono Int16 -> session.raw (spec 5.1 / 5.2)
func recordMic(seconds: Double, rawURL: URL, wavURL: URL) async throws -> (hwFormat: String, bytes: Int) {
    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    guard granted else {
        throw NSError(domain: "Screen2Prompt", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Microphone access denied. Grant it in System Settings > Privacy & Security > Microphone for your terminal, then re-run."
        ])
    }

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let hw = input.outputFormat(forBus: 0)
    guard hw.sampleRate > 0 else {
        throw NSError(domain: "Screen2Prompt", code: 2, userInfo: [NSLocalizedDescriptionKey: "No input device available."])
    }
    guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
          let converter = AVAudioConverter(from: hw, to: target) else {
        throw NSError(domain: "Screen2Prompt", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not build 16 kHz mono converter from \(hw)."])
    }

    let writer = try RawWriter(url: rawURL)
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
        if err != nil { return }
        if let ch = out.int16ChannelData, out.frameLength > 0 {
            writer.append(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
        }
    }

    engine.prepare()
    try engine.start()
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    input.removeTap(onBus: 0)
    engine.stop()
    writer.close()

    let pcm = try Data(contentsOf: rawURL)
    var wav = wavHeader(pcmLen: UInt32(pcm.count))
    wav.append(pcm)
    try wav.write(to: wavURL)
    return ("\(hw)", pcm.count)
}
