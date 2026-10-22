import Foundation

final class Results: @unchecked Sendable {
    let lock = NSLock()
    var values: [Double] = []
    func add(_ value: Double?) { lock.lock(); defer { lock.unlock() }; if let value { values.append(value) } }
    func snapshot() -> [Double] { lock.lock(); defer { lock.unlock() }; return values }
}

@main struct Check {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("recorder-meter-test-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        let source = root.appendingPathComponent("source.wav")
        let task = Process()
        task.executableURL = ffmpeg
        task.arguments = ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=8", "-ac", "2", "-c:a", "pcm_f32le", source.path]
        try task.run(); task.waitUntilExit(); precondition(task.terminationStatus == 0)
        let bytes = try Data(contentsOf: source)
        guard let header = LiveLoudness.waveHeader(bytes) else { fatalError("WAV header rejected") }
        let growing = root.appendingPathComponent("growing.wav")
        try bytes.prefix(header.start).write(to: growing)
        let writer = try FileHandle(forWritingTo: growing)
        try writer.seekToEnd()
        let meter = LiveLoudness(), results = Results()
        meter.start(file: growing, from: 0, ffmpeg: ffmpeg) { _, integrated, _ in results.add(integrated) }
        var offset = header.start
        var hadLiveResult = false
        while offset < bytes.count {
            let end = min(bytes.count, offset + 38400)
            try writer.write(contentsOf: bytes[offset..<end]); offset = end
            Thread.sleep(forTimeInterval: 0.05)
            if offset < bytes.count && !results.snapshot().isEmpty { hadLiveResult = true }
        }
        try writer.close()
        Thread.sleep(forTimeInterval: 1)
        meter.stop()
        let values = results.snapshot()
        precondition(hadLiveResult, "No readings until after recording ended")
        precondition(values.count > 10 && abs(values.last! - (-21.1)) < 1, "Unexpected sine loudness: \(values)")
        let reset = Results()
        meter.start(file: growing, from: 4, ffmpeg: ffmpeg) { _, integrated, _ in reset.add(integrated) }
        Thread.sleep(forTimeInterval: 2)
        meter.stop()
        precondition(!reset.snapshot().isEmpty, "Track reset produced no readings")
        precondition(LiveLoudness.parse("[ebur128] t: 1 S: -120.7 I: -70.0 LUFS")?.0 == nil)
        print("PASS: incremental PCM readings before EOF, sine LUFS=\(values.last!), restart at track offset, silence shown as unavailable")
    }
}
