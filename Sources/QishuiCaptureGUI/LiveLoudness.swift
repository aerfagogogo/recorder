import Foundation

/// Reads only newly written PCM bytes. Analysis never runs on the capture callback.
final class LiveLoudness: @unchecked Sendable {
    private let queue = DispatchQueue(label: "recorder.loudness", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var process: Process?
    private var input: FileHandle?
    private var reader: FileHandle?
    private var offset: UInt64 = 0
    private var alignment = 0
    private var pending = ""
    private var generation = UUID()

    func start(file: URL, from seconds: Double, ffmpeg: URL,
               update: @escaping @Sendable (Double?, Double?, String) -> Void) {
        queue.async { [self] in
            shutdown()
            let token = generation
            let clock = DispatchSource.makeTimerSource(queue: queue)
            timer = clock
            clock.schedule(deadline: .now(), repeating: .milliseconds(250))
            clock.setEventHandler { [weak self] in
                guard let self else { return }
                do {
                    if self.reader == nil {
                        guard FileManager.default.fileExists(atPath: file.path) else { return }
                        let handle = try FileHandle(forReadingFrom: file)
                        let header = try handle.read(upToCount: 65536) ?? Data()
                        guard let format = Self.waveHeader(header) else { try? handle.close(); return }
                        self.reader = handle
                        self.alignment = format.channels * format.bits / 8
                        self.offset = UInt64(format.start) + UInt64(max(0, seconds) * Double(format.rate)) * UInt64(self.alignment)
                        let task = Process()
                        let stdin = Pipe(), stderr = Pipe()
                        task.executableURL = ffmpeg
                        task.arguments = ["-hide_banner", "-nostats", "-loglevel", "info",
                            "-f", format.encoding, "-ar", String(format.rate), "-ac", String(format.channels),
                            "-probesize", "32", "-analyzeduration", "0",
                            "-i", "pipe:0", "-af", "ebur128=framelog=info", "-f", "null", "-"]
                        task.standardInput = stdin
                        task.standardOutput = FileHandle.nullDevice
                        task.standardError = stderr
                        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                            let data = handle.availableData
                            guard !data.isEmpty else { return }
                            self?.queue.async { [weak self] in
                                guard let self, self.generation == token else { return }
                                self.pending += String(decoding: data, as: UTF8.self)
                                while let end = self.pending.firstIndex(of: "\n") {
                                    let line = String(self.pending[..<end])
                                    self.pending.removeSubrange(...end)
                                    if let values = Self.parse(line) { update(values.0, values.1, "录制中估算 · 累计值随歌曲变化") }
                                }
                            }
                        }
                        task.terminationHandler = { [weak self] task in
                            let failed = task.terminationStatus != 0
                            self?.queue.async { [weak self] in
                                guard self?.generation == token, failed else { return }
                                update(nil, nil, "响度分析不可用，录音继续")
                            }
                        }
                        try task.run()
                        self.process = task
                        self.input = stdin.fileHandleForWriting
                    }
                    guard let reader = self.reader, self.process?.isRunning == true else { return }
                    let end = try reader.seekToEnd()
                    guard end > self.offset else { return }
                    let count = min(Int(end - self.offset), 262144) / self.alignment * self.alignment
                    guard count > 0 else { return }
                    try reader.seek(toOffset: self.offset)
                    let bytes = try reader.read(upToCount: count) ?? Data()
                    try self.input?.write(contentsOf: bytes)
                    self.offset += UInt64(bytes.count)
                } catch {
                    self.shutdown()
                    update(nil, nil, "响度分析不可用，录音继续")
                }
            }
            clock.resume()
        }
    }

    func stop() { queue.async { [self] in shutdown() } }

    private func shutdown() {
        generation = UUID()
        timer?.cancel(); timer = nil
        try? input?.close(); input = nil
        try? reader?.close(); reader = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        pending = ""
    }

    static func parse(_ line: String) -> (Double?, Double?)? {
        guard line.contains(" t:"),
              let regex = try? NSRegularExpression(pattern: "S:\\s*(-?[0-9.]+|-[iI]nf).*?I:\\s*(-?[0-9.]+|-[iI]nf)"),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        func value(_ index: Int) -> Double? {
            guard let range = Range(match.range(at: index), in: line),
                  let number = Double(line[range]), number.isFinite, number > -70 else { return nil }
            return number
        }
        return (value(1), value(2))
    }

    static func waveHeader(_ data: Data) -> (start: Int, rate: Int, channels: Int, bits: Int, encoding: String)? {
        func word(_ p: Int, _ n: Int) -> Int {
            (0..<n).reduce(0) { $0 | Int(data[p + $1]) << ($1 * 8) }
        }
        guard data.count >= 12, String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        var p = 12
        var format: (Int, Int, Int, String)?
        while p + 8 <= data.count {
            let name = String(decoding: data[p..<p+4], as: UTF8.self)
            let size = word(p+4, 4)
            if name == "data", let f = format { return (p+8, f.0, f.1, f.2, f.3) }
            guard size <= data.count - p - 8 else { return nil }
            if name == "fmt ", size >= 16 {
                var code = word(p+8, 2)
                if code == 65534, size >= 40 { code = word(p+32, 2) }
                let bits = word(p+22, 2), channels = word(p+10, 2), rate = word(p+12, 4)
                guard channels > 0, rate > 0 else { return nil }
                let encoding: String
                if code == 3, bits == 32 { encoding = "f32le" }
                else if code == 1, [16,24,32].contains(bits) { encoding = "s\(bits)le" }
                else { return nil }
                format = (rate, channels, bits, encoding)
            }
            p += 8 + size + size % 2
        }
        return nil
    }
}
