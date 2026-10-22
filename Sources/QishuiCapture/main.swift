import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

private enum OutputFormat: String, CaseIterable {
    case flac, wav, mp3, alac, aac

    var fileExtension: String {
        switch self {
        case .alac, .aac: "m4a"
        default: rawValue
        }
    }

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "flac": self = .flac
        case "wav": self = .wav
        case "mp3": self = .mp3
        default: return nil
        }
    }
}

private struct Options {
    var appName = "汽水"
    var output: URL?
    var format: OutputFormat = .flac
    var listApps = false
    var sampleRate = 48_000
    var channels = 2
    var silenceSeconds = 2.0
    var thresholdDB = -50.0
    var maximumSeconds: Double?
    var audioSeconds: Double?
    var keepWAV = false
    var trimSilence = true
    var allowSilence = false
    var mutePlayback = false
    var title: String?
    var artist: String?
    var album: String?

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        var formatWasSet = false

        func value(after flag: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw CaptureError.usage("\(flag) 后面缺少参数")
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--app":
                options.appName = try value(after: argument)
            case "--output", "-o":
                options.output = URL(fileURLWithPath: try value(after: argument))
            case "--format":
                let requested = try value(after: argument).lowercased()
                guard let format = OutputFormat(rawValue: requested) else {
                    throw CaptureError.usage("格式必须是 flac、wav、mp3、alac 或 aac")
                }
                options.format = format
                formatWasSet = true
            case "--sample-rate":
                guard let value = Int(try value(after: argument)), value > 0 else {
                    throw CaptureError.usage("采样率必须是正整数")
                }
                options.sampleRate = value
            case "--channels":
                guard let value = Int(try value(after: argument)), (1...2).contains(value) else {
                    throw CaptureError.usage("声道数只能是 1 或 2")
                }
                options.channels = value
            case "--silence-seconds":
                guard let value = Double(try value(after: argument)), value >= 0 else {
                    throw CaptureError.usage("静音时长必须大于或等于 0")
                }
                options.silenceSeconds = value
            case "--threshold-db":
                guard let value = Double(try value(after: argument)), value < 0 else {
                    throw CaptureError.usage("静音阈值必须是负数，例如 -50")
                }
                options.thresholdDB = value
            case "--max-seconds":
                guard let value = Double(try value(after: argument)), value > 0 else {
                    throw CaptureError.usage("最长录制时间必须大于 0")
                }
                options.maximumSeconds = value
            case "--audio-seconds":
                guard let value = Double(try value(after: argument)), value > 0 else {
                    throw CaptureError.usage("有效音频时长必须大于 0")
                }
                options.audioSeconds = value
            case "--keep-wav":
                options.keepWAV = true
            case "--mute-playback":
                options.mutePlayback = true
            case "--no-trim":
                options.trimSilence = false
            case "--allow-silence":
                options.allowSilence = true
            case "--title":
                options.title = try value(after: argument)
            case "--artist":
                options.artist = try value(after: argument)
            case "--album":
                options.album = try value(after: argument)
            case "--list-apps":
                options.listApps = true
            case "--help", "-h":
                throw CaptureError.help
            default:
                throw CaptureError.usage("未知参数：\(argument)")
            }
            index += 1
        }
        if !formatWasSet,
           let fileExtension = options.output?.pathExtension,
           let inferred = OutputFormat(fileExtension: fileExtension) {
            options.format = inferred
        }
        return options
    }
}

private enum CaptureError: Error, LocalizedError {
    case help
    case usage(String)
    case permissionDenied
    case appNotFound(String)
    case displayNotFound
    case noAudio
    case ffmpegNotFound
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .help:
            return nil
        case .usage(let message):
            return message
        case .permissionDenied:
            return "没有屏幕与系统音频录制权限。请到“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”授权，然后重新运行。"
        case .appNotFound(let name):
            return "没有找到名称包含“\(name)”的运行中应用。请先打开并播放前暂停在歌曲起点。"
        case .displayNotFound:
            return "没有找到可捕获的显示器。"
        case .noAudio:
            return "没有检测到有效声音。WAV 诊断文件已保留；请确认目标应用正在播放。"
        case .ffmpegNotFound:
            return "找不到 FFmpeg；WAV 已保留，但无法转成 FLAC。"
        case .ffmpegFailed(let message):
            return "FFmpeg 转换失败：\(message)"
        }
    }
}

private let usage = """
应用音频录制（仅用于你有权保存的内容）

用法：
  qishui-capture --list-apps
  qishui-capture [选项]

选项：
  --app <名称>              目标应用名称的一部分，默认“汽水”
  -o, --output <路径>       输出文件路径；默认保存到 Captures
  --format <格式>           flac、wav、mp3、alac 或 aac，默认 flac
  --sample-rate <Hz>        默认 48000
  --channels <1|2>          默认 2
  --silence-seconds <秒>    有声后连续静音多久自动停止，默认 2.0；设为 0 禁用
  --threshold-db <dBFS>     静音阈值，默认 -50
  --max-seconds <秒>        最长录制时间
  --audio-seconds <秒>      从检测到第一段声音起录满指定时长后停止
  --keep-wav                转换成功后仍保留临时无压缩 WAV
  --mute-playback           只采集目标应用，不向扬声器输出；USR1/USR2 可切换
  --no-trim                 不自动裁掉录制首尾的数字静音
  --title <歌名>            写入 FLAC 歌名
  --artist <歌手>           写入 FLAC 歌手
  --album <专辑>            写入 FLAC 专辑
  --allow-silence           即使全程静音也生成 FLAC（仅供诊断）
  --list-apps               列出可捕获的应用
  -h, --help                显示帮助

开始后再播放歌曲；按 Control-C 也可停止并保存。
"""

private final class AudioCaptureWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let outputURL: URL
    private let thresholdDB: Double
    private let silenceSeconds: Double
    private let audioSeconds: Double?
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var totalFrames: AVAudioFramePosition = 0
    private var silentFrames: AVAudioFramePosition = 0
    private var detectedSound = false
    private var firstSoundFrame: AVAudioFramePosition?
    private var requestedStop = false
    private var lastMeterPrint = Date.distantPast
    private var streamSampleRate = 0.0
    var onAutomaticStop: (@Sendable () -> Void)?

    init(outputURL: URL, thresholdDB: Double, silenceSeconds: Double, audioSeconds: Double?) {
        self.outputURL = outputURL
        self.thresholdDB = thresholdDB
        self.silenceSeconds = silenceSeconds
        self.audioSeconds = audioSeconds
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid else { return }

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription else {
                    return
                }

                var streamDescription = description
                guard let format = AVAudioFormat(streamDescription: &streamDescription),
                      let buffer = AVAudioPCMBuffer(
                        pcmFormat: format,
                        bufferListNoCopy: audioBufferList.unsafePointer
                      ) else {
                    return
                }

                try consume(buffer)
            }
        } catch {
            FileHandle.standardError.write(Data("\n写入音频失败：\(error.localizedDescription)\n".utf8))
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }

        if audioFile == nil {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: buffer.format.settings,
                commonFormat: buffer.format.commonFormat,
                interleaved: buffer.format.isInterleaved
            )
            streamSampleRate = buffer.format.sampleRate
        }

        try audioFile?.write(from: buffer)
        totalFrames += AVAudioFramePosition(buffer.frameLength)

        let decibels = meterDB(for: buffer)
        if decibels > thresholdDB {
            if !detectedSound {
                firstSoundFrame = totalFrames - AVAudioFramePosition(buffer.frameLength)
            }
            detectedSound = true
            silentFrames = 0
        } else if detectedSound {
            silentFrames += AVAudioFramePosition(buffer.frameLength)
        }

        if Date().timeIntervalSince(lastMeterPrint) >= 0.5 {
            let elapsed = streamSampleRate > 0 ? Double(totalFrames) / streamSampleRate : 0
            let line = String(format: "\r录制中 %6.1f 秒 | %6.1f dBFS", elapsed, decibels)
            FileHandle.standardError.write(Data(line.utf8))
            lastMeterPrint = Date()
        }

        if detectedSound,
           silenceSeconds > 0,
           streamSampleRate > 0,
           Double(silentFrames) / streamSampleRate >= silenceSeconds,
           !requestedStop {
            requestedStop = true
            onAutomaticStop?()
        }

        if let audioSeconds,
           let firstSoundFrame,
           streamSampleRate > 0,
           Double(totalFrames - firstSoundFrame) / streamSampleRate >= audioSeconds,
           !requestedStop {
            requestedStop = true
            onAutomaticStop?()
        }
    }

    private func meterDB(for buffer: AVAudioPCMBuffer) -> Double {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return -160 }

        var sum = 0.0
        var count = 0

        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = channels[channel]
                for frame in 0..<frames {
                    let sample = Double(samples[frame])
                    sum += sample * sample
                }
                count += frames
            }
        } else if let channels = buffer.int16ChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = channels[channel]
                for frame in 0..<frames {
                    let sample = Double(samples[frame]) / Double(Int16.max)
                    sum += sample * sample
                }
                count += frames
            }
        }

        guard count > 0, sum > 0 else { return -160 }
        return 20 * log10(sqrt(sum / Double(count)))
    }

    func finish() -> (frames: AVAudioFramePosition, sampleRate: Double, heardSound: Bool) {
        lock.lock()
        defer { lock.unlock() }
        audioFile = nil
        return (totalFrames, streamSampleRate, detectedSound)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        FileHandle.standardError.write(Data("\n捕获流停止：\(error.localizedDescription)\n".utf8))
        onAutomaticStop?()
    }
}

private func outputURLs(from options: Options) -> (temporaryWAV: URL, output: URL) {
    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let defaultOutput = currentDirectory
        .appendingPathComponent("Captures", isDirectory: true)
        .appendingPathComponent("capture-\(formatter.string(from: Date())).\(options.format.fileExtension)")
    let requested = options.output ?? defaultOutput
    let output = requested.pathExtension.lowercased() == options.format.fileExtension
        ? requested
        : requested.deletingPathExtension().appendingPathExtension(options.format.fileExtension)
    let temporaryWAV = output.deletingPathExtension().appendingPathExtension("capture.wav")
    return (temporaryWAV.standardizedFileURL, output.standardizedFileURL)
}

private func findFFmpeg() -> URL? {
    let candidates = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ]
    return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        .map(URL.init(fileURLWithPath:))
}

private func convertOutput(wav: URL, output: URL, options: Options) throws {
    guard let ffmpeg = findFFmpeg() else { throw CaptureError.ffmpegNotFound }
    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let process = Process()
    let errorPipe = Pipe()
    process.executableURL = ffmpeg
    var arguments = [
        "-hide_banner", "-loglevel", "error", "-y",
        "-i", wav.path
    ]
    if options.trimSilence {
        arguments += [
            "-af",
            "silenceremove=start_periods=1:start_duration=0.05:start_threshold=-70dB:stop_periods=1:stop_duration=0.5:stop_threshold=-70dB"
        ]
    }
    arguments += ["-map_metadata", "0"]
    if let title = options.title { arguments += ["-metadata", "title=\(title)"] }
    if let artist = options.artist { arguments += ["-metadata", "artist=\(artist)"] }
    if let album = options.album { arguments += ["-metadata", "album=\(album)"] }
    switch options.format {
    case .flac:
        arguments += ["-c:a", "flac", "-compression_level", "8"]
    case .wav:
        arguments += ["-c:a", "pcm_s24le", "-ar", "48000", "-ac", "2"]
    case .mp3:
        arguments += ["-c:a", "libmp3lame", "-b:a", "320k"]
    case .alac:
        arguments += ["-c:a", "alac"]
    case .aac:
        arguments += ["-c:a", "aac", "-b:a", "256k"]
    }
    arguments += [output.path]
    process.arguments = arguments
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        throw CaptureError.ffmpegFailed(String(decoding: data, as: UTF8.self))
    }
}

private enum QishuiCapture {
    static func main() async {
        do {
            let options: Options
            do {
                options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            } catch CaptureError.help {
                print(usage)
                return
            }

            try await run(options)
        } catch {
            if let description = (error as? LocalizedError)?.errorDescription,
               !description.isEmpty {
                FileHandle.standardError.write(Data("错误：\(description)\n\n".utf8))
            }
            if case CaptureError.usage = error {
                FileHandle.standardError.write(Data(usage.utf8))
            }
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run(_ options: Options) async throws {
        if options.listApps {
            let applications = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .sorted {
                    ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending
                }
            for application in applications {
                print("\(application.localizedName ?? "未知应用")\tpid=\(application.processIdentifier)\tbundle=\(application.bundleIdentifier ?? "")")
            }
            return
        }

        let application = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.localizedCaseInsensitiveCompare(options.appName) == .orderedSame
            || $0.localizedName?.localizedCaseInsensitiveCompare(options.appName) == .orderedSame
        }) ?? NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier?.localizedCaseInsensitiveContains(options.appName) == true
            || $0.localizedName?.localizedCaseInsensitiveContains(options.appName) == true
        })
        guard let application, let bundleID = application.bundleIdentifier else {
            throw CaptureError.appNotFound(options.appName)
        }

        let urls = outputURLs(from: options)
        let recorder = ProcessTapRecorder(
            targetBundleID: bundleID,
            outputURL: urls.temporaryWAV,
            thresholdDB: options.thresholdDB,
            silenceSeconds: options.silenceSeconds,
            audioSeconds: options.audioSeconds,
            mutePlayback: options.mutePlayback
        )

        let stopSignal = AsyncStream<Void> { continuation in
            recorder.onAutomaticStop = { continuation.yield() }

            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            source.setEventHandler { continuation.yield() }
            source.resume()

            signal(SIGUSR1, SIG_IGN)
            signal(SIGUSR2, SIG_IGN)
            let monitorQueue = DispatchQueue(label: "recorder.monitor-control")
            let muteSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: monitorQueue)
            let unmuteSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: monitorQueue)
            for (control, muted) in [(muteSource, true), (unmuteSource, false)] {
                control.setEventHandler {
                    do { try recorder.setPlaybackMuted(muted) }
                    catch { FileHandle.standardError.write(Data("\nMONITOR_ERROR=\(error.localizedDescription)\n".utf8)) }
                }
                control.resume()
            }

            if let maximumSeconds = options.maximumSeconds {
                DispatchQueue.global().asyncAfter(deadline: .now() + maximumSeconds) {
                    continuation.yield()
                }
            }

            continuation.onTermination = { _ in
                source.cancel(); muteSource.cancel(); unmuteSource.cancel()
            }
        }

        print("目标应用：\(application.localizedName ?? bundleID)（bundle \(bundleID)）")
        print("临时 WAV：\(urls.temporaryWAV.path)")
        print("现在播放歌曲；按 Control-C 停止。")

        try recorder.start()
        try recorder.setPlaybackMuted(options.mutePlayback)
        FileHandle.standardOutput.write(Data("CAPTURE_READY\n".utf8))
        for await _ in stopSignal { break }
        let result = recorder.stop()
        FileHandle.standardError.write(Data("\n".utf8))
        guard result.frames > 0, result.heardSound || options.allowSilence else {
            throw CaptureError.noAudio
        }

        let duration = result.sampleRate > 0 ? Double(result.frames) / result.sampleRate : 0
        print(String(format: "已捕获 %.2f 秒音频。", duration))
        try convertOutput(wav: urls.temporaryWAV, output: urls.output, options: options)

        if !options.keepWAV {
            try? FileManager.default.removeItem(at: urls.temporaryWAV)
        }

        print("完成：\(urls.output.path)")
        if !result.heardSound {
            print("提示：整段音频都低于静音阈值，请试听确认或调整 --threshold-db。")
        }
    }
}

await QishuiCapture.main()
