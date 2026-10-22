import AppKit
import ApplicationServices
import Combine
import Dispatch
import Foundation
import SwiftUI

private enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case flac = "FLAC"
    case wav = "WAV"
    case mp3 = "MP3"
    case alac = "ALAC"
    case aac = "AAC"

    var id: String { rawValue }
    var commandValue: String { rawValue.lowercased() }
    var fileExtension: String {
        switch self {
        case .alac, .aac: "m4a"
        default: commandValue
        }
    }
    var detail: String {
        switch self {
        case .flac: "无损压缩，推荐收藏"
        case .wav: "24-bit/48 kHz，设备兼容性最高"
        case .mp3: "320 kbps，通用且体积较小"
        case .alac: "Apple 无损"
        case .aac: "256 kbps，适合手机"
        }
    }
}

private enum RecordingMode: String, CaseIterable, Identifiable {
    case manual = "手动停止"
    case single = "单曲"
    case continuous = "连续"

    static let userChoices: [RecordingMode] = [.single, .continuous]

    var id: String { rawValue }
    var detail: String {
        switch self {
        case .manual: "由你点击停止，适合任意内容"
        case .single: "完整录完当前歌曲后自动结束"
        case .continuous: "自动保存每首完整歌曲，未播完的最后一首丢弃"
        }
    }
}

private struct DetectedTrack: Sendable {
    let title: String
    let artist: String
    let album: String
    let elapsed: TimeInterval?
    let duration: TimeInterval?
    let playbackStartedAt: TimeInterval?
    let positionAnchorElapsed: TimeInterval?

    init(
        title: String,
        artist: String,
        album: String,
        elapsed: TimeInterval?,
        duration: TimeInterval?,
        playbackStartedAt: TimeInterval? = nil,
        positionAnchorElapsed: TimeInterval? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.elapsed = elapsed
        self.duration = duration
        self.playbackStartedAt = playbackStartedAt
        self.positionAnchorElapsed = positionAnchorElapsed
    }
}

private struct SystemNowPlayingInfo: Sendable {
    let processIdentifier: pid_t
    let track: DetectedTrack
    let playbackRate: Double
}

private struct NowPlayingAgentMessage: Decodable, Sendable {
    let processIdentifier: pid_t
    let title: String
    let artist: String
    let album: String
    let elapsed: Double
    let duration: Double
    let playbackRate: Double
    let playbackStartedAt: Double
    let positionAnchorElapsed: Double
}

private struct TrackSegment: Sendable {
    let title: String
    let artist: String
    let album: String
    let start: TimeInterval
}

private struct CompletedTrack: Sendable {
    let segment: TrackSegment
    let end: TimeInterval
}

private struct SplitSpec: Sendable {
    let source: URL
    let output: URL
    let start: TimeInterval
    let duration: TimeInterval?
    let title: String
    let artist: String
    let album: String
    let codecArguments: [String]
    let trimLeadingSilence: Bool
}

private struct PlayerApplication: Identifiable, Hashable {
    let name: String
    let bundleIdentifier: String
    var id: String { bundleIdentifier }
}

@MainActor
private final class RecorderModel: ObservableObject {
    @Published var targetApp = "com.soda.music"
    @Published var detectedPlayers: [PlayerApplication] = []
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var format: ExportFormat = .flac
    @Published var recordingMode: RecordingMode = .single
    @Published var outputFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs/录音机音乐",
            isDirectory: true
        ).path
    @Published var isRecording = false
    @Published var isFinishing = false
    @Published var status = "单曲模式会读取总时长并自动停止"
    @Published var levelDB = -160.0
    @Published var mutePlayback = false
    @Published var monitorStatus = "只屏蔽所选播放器的外放，不改变录音音量"
    @Published var monitorPending = false
    @Published var captureReady = false
    @Published var signalWarning = ""
    private var lowSignalSince: Date?
    private var monitorBuffer = ""

    func changeMonitoring() {
        guard let process, process.isRunning, isRecording else { return }
        monitorPending = true
        monitorStatus = "正在切换监听…"
        if kill(process.processIdentifier, mutePlayback ? SIGUSR1 : SIGUSR2) != 0 {
            monitorPending = false
            monitorStatus = "监听切换失败，录音未停止"
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.monitorPending else { return }
            self.monitorPending = false
            self.monitorStatus = "未收到监听切换确认，请重试；录音继续"
        }
    }

    private func receiveMonitorStatus(_ text: String) {
        monitorBuffer += text
        while let end = monitorBuffer.firstIndex(of: "\n") {
            let line = String(monitorBuffer[..<end])
            monitorBuffer.removeSubrange(...end)
            if line.contains("MONITOR_MUTED=") {
                monitorPending = false
                monitorStatus = line.contains("MONITOR_MUTED=1")
                    ? "静音监听已生效 · 目标应用仍被采集" : "正常监听已恢复 · 录音继续"
            } else if line.contains("MONITOR_ERROR=") {
                monitorPending = false
                monitorStatus = "监听切换失败，录音继续；请勿静音播放器本身"
            }
        }
        if monitorBuffer.count > 4096 { monitorBuffer = String(monitorBuffer.suffix(2048)) }
    }
    @Published var shortLUFS: Double?
    @Published var integratedLUFS: Double?
    @Published var loudnessStatus = "等待录制 · 前 3 秒积累响度数据"
    private let loudness = LiveLoudness()
    private var loudnessFile: URL?
    private var loudnessStart: Double?
    private var loudnessGeneration = UUID()

    private func updateLoudnessTrack() {
        guard isRecording, let segment = trackSegments.last, let file = loudnessFile,
              loudnessStart != segment.start else { return }
        loudnessStart = segment.start
        loudnessGeneration = UUID()
        let token = loudnessGeneration
        shortLUFS = nil; integratedLUFS = nil
        loudnessStatus = "前 3 秒积累数据 · 累计值为录制中估算"
        guard let ffmpeg = ffmpegURL() else {
            loudnessStatus = "缺少 FFmpeg，响度分析不可用"
            return
        }
        loudness.start(file: file, from: segment.start, ffmpeg: ffmpeg) { [weak self] short, integrated, message in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording, self.loudnessGeneration == token else { return }
                self.shortLUFS = short
                self.integratedLUFS = integrated
                self.loudnessStatus = message
            }
        }
    }
    @Published var lastOutput: URL?
    @Published var conversionInput = ""
    @Published var conversionFormat: ExportFormat = .wav
    @Published var conversionStatus = "选择已有音频，可读取标签并转换格式"
    @Published var isConverting = false

    private var process: Process?
    private var conversionProcess: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var recorderErrorText = ""
    private var recordingStartedAt: Date?
    private var trackTimer: Timer?
    private var permissionTimer: Timer?
    private var permissionPollAttempts = 0
    private var screenCaptureRequestIssued = false
    private var trackSegments: [TrackSegment] = []
    private var completedTracks: [CompletedTrack] = []
    private var singleEndTime: TimeInterval?
    private var singleTrackDuration: TimeInterval?
    private var lastDetectedTrack: DetectedTrack?
    private var lastProgressAdvanceAt: Date?
    private var missingTrackSince: Date?
    private var discardUnfinishedTail = false
    private var currentTrackStartedNearBeginning = false
    private var heardAudioSinceStart = false
    private var userCancelledBeforeAudio = false
    private var cachedNowPlaying: SystemNowPlayingInfo?
    private var nowPlayingReceivedAt = Date.distantPast
    @Published var isReadingTrack = false
    private var trackReadID = UUID()
    private var nowPlayingAgent: Process?
    private var nowPlayingAgentTarget: String?
    private var nowPlayingAgentID = UUID()
    private var nowPlayingPipe: Pipe?
    private var nowPlayingBuffer = Data()
    private var activeMode: RecordingMode = .manual
    private var intendedOutput: URL?

    init() {
        refreshPlayers()
    }

    var levelProgress: Double {
        max(0, min(1, (levelDB + 60) / 60))
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择录音保存文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: outputFolder)
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url.path
        }
    }

    func refreshPlayers() {
        let keywords = [
            "汽水", "音乐", "music", "spotify", "网易云", "qq音乐", "酷狗", "酷我",
            "vlc", "iina", "foobar", "audirvana", "chrome", "safari", "edge", "firefox"
        ]
        let players: [PlayerApplication] = NSWorkspace.shared.runningApplications.compactMap { application -> PlayerApplication? in
            guard let name = application.localizedName,
                  let bundleIdentifier = application.bundleIdentifier,
                  application.activationPolicy == .regular,
                  !bundleIdentifier.hasPrefix("com.sunyiting.qishui-audio-capture") else { return nil }
            let excludedWords = ["helper", "networking", "graphics", "自动填充", "sharesheet", "web content"]
            guard !excludedWords.contains(where: { name.localizedCaseInsensitiveContains($0) }) else { return nil }
            let matches = keywords.contains(where: { name.localizedCaseInsensitiveContains($0) })
                || keywords.contains(where: { bundleIdentifier.localizedCaseInsensitiveContains($0) })
            guard matches else { return nil }
            return PlayerApplication(name: name, bundleIdentifier: bundleIdentifier)
        }
        detectedPlayers = players
        .reduce(into: [PlayerApplication]()) { result, application in
            if !result.contains(where: { $0.bundleIdentifier == application.bundleIdentifier }) {
                result.append(application)
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if detectedPlayers.contains(where: { $0.bundleIdentifier == "com.soda.music" }) {
            targetApp = "com.soda.music"
        } else if !detectedPlayers.contains(where: { $0.bundleIdentifier == targetApp }),
                  let first = detectedPlayers.first {
            targetApp = first.bundleIdentifier
        }
    }

    func chooseConversionInput() {
        let panel = NSOpenPanel()
        panel.title = "选择要转换的音频"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            _ = acceptConversionDrop([url])
        }
    }

    @discardableResult
    func acceptConversionDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            conversionStatus = "请拖入一个音频文件，不要拖入文件夹"
            return false
        }
        conversionInput = url.path
        conversionStatus = "已选择 \(url.lastPathComponent)，正在读取标签…"
        readMetadata(from: url)
        return true
    }

    func convertExistingFile() {
        guard !isConverting else { return }
        let input = URL(fileURLWithPath: conversionInput)
        guard FileManager.default.fileExists(atPath: input.path) else {
            conversionStatus = "请先选择有效的音频文件"
            return
        }
        guard let ffmpeg = ffmpegURL() else {
            conversionStatus = "找不到 FFmpeg"
            return
        }

        let output = uniqueURL(
            in: input.deletingLastPathComponent(),
            baseName: input.deletingPathExtension().lastPathComponent,
            extension: conversionFormat.fileExtension
        )
        let task = Process()
        let errorPipe = Pipe()
        task.executableURL = ffmpeg
        var arguments = ["-hide_banner", "-loglevel", "error", "-i", input.path, "-map_metadata", "0"]
        arguments += codecArguments(for: conversionFormat)
        arguments += [output.path]
        task.arguments = arguments
        task.standardError = errorPipe
        task.terminationHandler = { [weak self] finishedTask in
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: errorData, as: UTF8.self)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.conversionProcess = nil
                self.isConverting = false
                if finishedTask.terminationStatus == 0,
                   FileManager.default.fileExists(atPath: output.path) {
                    self.lastOutput = output
                    self.conversionStatus = "转换完成：\(output.lastPathComponent)"
                } else {
                    self.conversionStatus = "转换失败：\(message.isEmpty ? "未知错误" : message)"
                }
            }
        }
        do {
            try task.run()
            conversionProcess = task
            isConverting = true
            conversionStatus = "正在转换为 \(conversionFormat.rawValue)…"
        } catch {
            conversionStatus = "转换启动失败：\(error.localizedDescription)"
        }
    }

    func readCurrentTrack() {
        guard !isRecording, !isFinishing, !isReadingTrack else { return }
        guard let player = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == targetApp
        }) else {
            status = "没有找到所选播放器"
            return
        }
        let requestID = UUID()
        trackReadID = requestID
        let requestedAt = Date()
        let selectedApp = targetApp
        isReadingTrack = true
        status = "正在读取当前歌曲…"
        startNowPlayingAgent()
        Task { @MainActor [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.trackReadID == requestID else { return }
                guard !self.isRecording, !self.isFinishing, self.targetApp == selectedApp else {
                    self.isReadingTrack = false
                    return
                }
                if self.nowPlayingReceivedAt >= requestedAt,
                   let info = self.cachedNowPlaying,
                   info.processIdentifier == player.processIdentifier {
                    self.isReadingTrack = false
                    self.applyTrackPreview(info)
                    return
                }
                if self.nowPlayingAgent?.isRunning != true {
                    self.isReadingTrack = false
                    self.status = "歌曲信息助手未能运行，请检查本机 Swift 运行环境"
                    return
                }
            }
            guard let self, self.trackReadID == requestID else { return }
            self.isReadingTrack = false
            self.status = "未收到所选播放器的歌曲信息；请确认它正在播放后重试"
        }
    }

    private func applyTrackPreview(_ nowPlaying: SystemNowPlayingInfo) {
        let track = nowPlaying.track
        title = track.title
        artist = track.artist
        album = track.album
        let durationText = track.duration.map(Self.clockText) ?? "--:--"
        status = "已读取：\(track.title) — \(track.artist) · \(durationText)"
        if album.isEmpty { lookupAlbum(title: track.title, artist: track.artist) }
    }

    func start() {
        guard !isRecording, !isFinishing else { return }
        trackReadID = UUID()
        isReadingTrack = false
        guard requestRequiredPermissions() else {
            waitForPermissionCompletion()
            return
        }
        permissionTimer?.invalidate()
        permissionTimer = nil
        startNowPlayingAgent()
        guard let tool = captureToolURL() else {
            status = "找不到录制核心 qishui-capture，请重新打包应用"
            return
        }

        let folder = URL(fileURLWithPath: outputFolder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            status = "无法创建保存文件夹：\(error.localizedDescription)"
            return
        }

        activeMode = recordingMode
        trackSegments = []
        completedTracks = []
        singleEndTime = nil
        singleTrackDuration = nil
        lastDetectedTrack = nil
        lastProgressAdvanceAt = nil
        missingTrackSince = nil
        discardUnfinishedTail = false
        currentTrackStartedNearBeginning = false
        heardAudioSinceStart = false
        userCancelledBeforeAudio = false
        cachedNowPlaying = nil

        let baseName = safeFilename(title.isEmpty ? defaultFilename() : title)
        let finalOutput = uniqueURL(in: folder, baseName: baseName, extension: format.fileExtension)
        intendedOutput = activeMode == .manual ? finalOutput : nil
        let captureOutput: URL
        if activeMode == .manual {
            captureOutput = finalOutput
        } else {
            captureOutput = folder
                .appendingPathComponent(".qishui-session-\(UUID().uuidString)")
                .appendingPathExtension("flac")
        }
        let task = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.executableURL = tool
        var captureArguments = [
            "--app", targetApp,
            "--format", activeMode == .manual ? format.commandValue : "flac",
            "--output", captureOutput.path,
            "--silence-seconds", "0",
            "--title", title,
            "--artist", artist,
            "--album", album
        ]
        if activeMode != .manual { captureArguments.append("--no-trim") }
        if mutePlayback { captureArguments.append("--mute-playback") }
        task.arguments = captureArguments
        task.standardOutput = outPipe
        task.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            guard text.contains("CAPTURE_READY") else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.recordingStartedAt = Date()
                self.captureReady = true
                self.status = self.activeMode == .single
                    ? "已就绪，等待你从歌曲开头播放…"
                    : "连续录制已就绪，等待播放…"
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            let parsedLevel = Self.lastDBFS(in: text)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiveMonitorStatus(text)
                if let parsedLevel {
                    self.levelDB = parsedLevel
                    if parsedLevel <= -80, self.heardAudioSinceStart, (self.cachedNowPlaying?.playbackRate ?? 0) > 0 {
                        if self.lowSignalSince == nil { self.lowSignalSince = Date() }
                        if Date().timeIntervalSince(self.lowSignalSince!) >= 3 {
                            self.signalWarning = "播放中持续无声：请检查播放器是否静音。也可能是歌曲本身的安静段。"
                        }
                    } else {
                        self.lowSignalSince = nil
                        self.signalWarning = ""
                    }
                    if parsedLevel > -70, !self.heardAudioSinceStart {
                        self.heardAudioSinceStart = true
                        if self.trackSegments.isEmpty {
                            self.status = "已检测到播放，正在读取歌曲名称和总时长…"
                        }
                    }
                }
                if text.contains("错误：") || text.contains("没有找到") || text.contains("权限") {
                    self.recorderErrorText += text
                }
            }
        }
        task.terminationHandler = { [weak self] finishedTask in
            let code = finishedTask.terminationStatus
            Task { @MainActor [weak self] in
                self?.didFinish(exitCode: code, output: captureOutput)
            }
        }

        do {
            try task.run()
            process = task
            stdoutPipe = outPipe
            stderrPipe = errPipe
            lastOutput = nil
            loudness.stop()
            captureReady = false
            lowSignalSince = nil
            signalWarning = ""
            monitorBuffer = ""
            monitorPending = false
            monitorStatus = mutePlayback ? "静音监听开启 · 请保持播放器自身音量正常" : "正常监听 · 可随时开启静音监听"
            loudnessFile = captureOutput.deletingPathExtension().appendingPathExtension("capture.wav")
            loudnessStart = nil
            shortLUFS = nil; integratedLUFS = nil
            loudnessStatus = "等待识别本首起点 · 电平条随声音变化"
            levelDB = -160
            recorderErrorText = ""
            isRecording = true
            recordingStartedAt = nil
            if activeMode != .manual { startTrackMonitoring() }
            if activeMode == .single {
                status = "正在启动系统音频录制；首次使用请完成授权…"
            } else if activeMode == .continuous {
                status = "正在启动连续录制；首次使用请完成授权…"
            } else {
                status = "正在录制：现在播放歌曲，结束时点“停止并保存”"
            }
        } catch {
            status = "启动失败：\(error.localizedDescription)"
        }
    }

    private func requestRequiredPermissions() -> Bool {
        // Core Audio Process Tap 会在真正开始录音时请求“系统音频录制”
        // 权限，不再依赖屏幕录制权限，也不会因显示器休眠而中断。
        true
    }

    private func waitForPermissionCompletion() {
        guard permissionTimer == nil else { return }
        permissionPollAttempts = 0
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.permissionPollAttempts += 1
                let captureGranted = CGPreflightScreenCaptureAccess()
                if captureGranted {
                    self.permissionTimer?.invalidate()
                    self.permissionTimer = nil
                    self.status = "授权完成，请再次点击“开始录制”"
                } else if self.permissionPollAttempts >= 120 {
                    self.permissionTimer?.invalidate()
                    self.permissionTimer = nil
                    self.status = "授权尚未完成；请在系统设置中允许录音机后再点“开始录制”"
                }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        userCancelledBeforeAudio = !heardAudioSinceStart
        let observed = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if activeMode == .single {
            discardUnfinishedTail = !currentTrackStartedNearBeginning || !Self.isAtTrackEnd(lastDetectedTrack)
            if !discardUnfinishedTail { singleEndTime = observed }
        } else if activeMode == .continuous {
            completeContinuousTailIfAtEnd(observed: observed)
        }
        status = "正在结束录制并整理已完整播放的歌曲…"
        interruptCapture()
    }

    private func interruptCapture() {
        guard isRecording, let process else { return }
        isRecording = false
        isFinishing = true
        process.interrupt()
    }

    func revealOutput() {
        if let lastOutput {
            NSWorkspace.shared.activateFileViewerSelecting([lastOutput])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: outputFolder, isDirectory: true))
        }
    }

    private func didFinish(exitCode: Int32, output: URL) {
        captureReady = false
        lowSignalSince = nil
        signalWarning = ""
        monitorPending = false
        monitorStatus = "录制已结束，目标应用外放已恢复"
        loudness.stop()
        loudnessGeneration = UUID()
        loudnessStatus = "录制已结束 · 以上为实时估算，成品需另行复核"
        stopTrackMonitoring()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        isRecording = false
        isFinishing = false
        levelDB = -160

        let diagnosticWAV = output.deletingPathExtension().appendingPathExtension("capture.wav")
        if exitCode == 0, FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.removeItem(at: diagnosticWAV)
            if activeMode == .manual {
                lastOutput = output
                status = "保存完成：\(output.lastPathComponent)"
            } else if activeMode == .single, discardUnfinishedTail {
                try? FileManager.default.removeItem(at: output)
                status = "播放在歌曲结束前停止，未完整的录音已丢弃"
            } else {
                splitRecordedSession(output)
            }
        } else if userCancelledBeforeAudio {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: diagnosticWAV)
            status = "已取消等待，没有生成文件"
        } else if FileManager.default.fileExists(atPath: diagnosticWAV.path),
                  !completedTracks.isEmpty {
            status = "录制意外中断，正在抢救已经完整播放的歌曲…"
            splitRecordedSession(diagnosticWAV, deleteSourceAfterSuccess: false)
        } else {
            let detail = recorderErrorText
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            status = detail.isEmpty ? "录制失败或没有检测到声音，请确认所选播放器正在播放" : detail
        }
    }

    private func detectSelectedTrack() -> DetectedTrack? {
        guard let player = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == targetApp
        }),
        let nowPlaying = cachedNowPlaying,
        Date().timeIntervalSince(nowPlayingReceivedAt) < 2,
        nowPlaying.processIdentifier == player.processIdentifier else { return nil }
        return nowPlaying.track
    }

    private func refreshSystemNowPlaying() {
        startNowPlayingAgent()
    }

    private func startNowPlayingAgent() {
        guard nowPlayingAgent?.isRunning != true || nowPlayingAgentTarget != targetApp else { return }
        if nowPlayingAgent?.isRunning == true { nowPlayingAgent?.terminate() }
        nowPlayingAgentTarget = targetApp
        nowPlayingAgentID = UUID()
        cachedNowPlaying = nil
        nowPlayingReceivedAt = .distantPast
        let bundledExecutable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/now-playing-agent")
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("NowPlayingAgent.swift")
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("AppBundle/NowPlayingAgent.swift")
        // On this macOS installation the compiled helper receives no MediaRemote
        // results. Prefer the verified Swift-hosted route when its source exists.
        if ![bundled, development].compactMap({ $0 }).contains(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }), FileManager.default.isExecutableFile(atPath: bundledExecutable.path) {
            launchNowPlayingAgent(executable: bundledExecutable, arguments: [
                String(ProcessInfo.processInfo.processIdentifier), targetApp
            ])
            return
        }
        guard let script = [bundled, development].compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            status = "缺少歌曲信息读取程序，请重新安装录音机"
            return
        }

        launchNowPlayingAgent(
            executable: URL(fileURLWithPath: "/usr/bin/swift"),
            arguments: [script.path, String(ProcessInfo.processInfo.processIdentifier), targetApp]
        )
    }

    private func launchNowPlayingAgent(executable: URL, arguments: [String]) {
        nowPlayingPipe?.fileHandleForReading.readabilityHandler = nil
        nowPlayingBuffer.removeAll(keepingCapacity: true)
        let task = Process()
        let pipe = Pipe()
        let agentID = nowPlayingAgentID
        task.executableURL = executable
        task.arguments = arguments
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard self?.nowPlayingAgentID == agentID else { return }
                self?.consumeNowPlayingData(data)
            }
        }
        do {
            try task.run()
            nowPlayingAgent = task
            nowPlayingPipe = pipe
        } catch {
            status = "歌曲信息读取程序启动失败：\(error.localizedDescription)"
        }
    }

    private func consumeNowPlayingData(_ data: Data) {
        nowPlayingBuffer.append(data)
        while let newline = nowPlayingBuffer.firstIndex(of: 0x0A) {
            let line = nowPlayingBuffer[..<newline]
            nowPlayingBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let message = try? JSONDecoder().decode(NowPlayingAgentMessage.self, from: Data(line)),
                  !message.title.isEmpty,
                  message.duration > 0 else { continue }
            cachedNowPlaying = SystemNowPlayingInfo(
                processIdentifier: message.processIdentifier,
                track: DetectedTrack(
                    title: message.title,
                    artist: message.artist,
                    album: message.album,
                    elapsed: message.elapsed,
                    duration: message.duration,
                    playbackStartedAt: message.playbackStartedAt > 0
                        ? message.playbackStartedAt
                        : nil,
                    positionAnchorElapsed: message.positionAnchorElapsed
                ),
                playbackRate: message.playbackRate
            )
            nowPlayingReceivedAt = Date()
        }
    }

    private func startTrackMonitoring() {
        trackTimer?.invalidate()
        trackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSystemNowPlaying()
                self?.pollCurrentTrack()
                self?.updateLoudnessTrack()
            }
        }
        refreshSystemNowPlaying()
    }

    private func stopTrackMonitoring() {
        trackTimer?.invalidate()
        trackTimer = nil
        recordingStartedAt = nil
    }

    private func pollCurrentTrack() {
        guard isRecording,
              activeMode != .manual,
              let started = recordingStartedAt else { return }

        let now = Date()
        let observed = now.timeIntervalSince(started)
        guard let detected = detectSelectedTrack() else {
            // 尚未播放时允许一直等待，不把“还没开始”误判为录制失败。
            guard !trackSegments.isEmpty else { return }
            if missingTrackSince == nil { missingTrackSince = now }
            if let missingTrackSince, now.timeIntervalSince(missingTrackSince) >= 3 {
                if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == targetApp }) {
                    // Metadata loss is not an audio stop. Keep the selected tap
                    // (and its mute) alive; never extrapolate an unverified end.
                    currentTrackStartedNearBeginning = false
                    lastProgressAdvanceAt = nil
                    status = "歌曲信息暂不可用，仍在采集所选播放器；当前片段需重新确认完整起点"
                    return
                }
                if activeMode == .single {
                    discardUnfinishedTail = true
                } else {
                    completeContinuousTailIfAtEnd(observed: observed)
                }
                status = "播放器已停止或退出，正在保存已完整播放的歌曲…"
                interruptCapture()
            }
            return
        }
        missingTrackSince = nil

        // 录制核心已经在等声音；歌曲信息在播放器真正准备好后再附加。
        if trackSegments.isEmpty {
            guard detected.elapsed != nil,
                  let duration = detected.duration,
                  duration > 0 else {
                if heardAudioSinceStart {
                    status = "已检测到声音，正在等待播放器提供完整进度和总时长…"
                }
                return
            }
            guard let exactStart = sessionStartOffset(for: detected, recordingStartedAt: started) else {
                status = "已检测到声音，正在等待播放器提供精确播放时间戳…"
                return
            }
            title = detected.title
            artist = detected.artist
            album = detected.album
            lastDetectedTrack = detected
            singleTrackDuration = duration
            currentTrackStartedNearBeginning = exactStart >= 0
            trackSegments = [TrackSegment(
                title: detected.title,
                artist: detected.artist,
                album: detected.album,
                start: max(0, exactStart)
            )]
            status = currentTrackStartedNearBeginning
                ? "已识别：\(detected.title) — \(detected.artist) · \(Self.clockText(duration))"
                : "当前歌曲开始于录音之前；请重新点击要录制的歌曲，从头播放即可"
            return
        }

        guard let previous = trackSegments.last else { return }

        let playbackSessionChanged = Self.playbackSessionChanged(from: lastDetectedTrack, to: detected)
        if detected.title != previous.title || detected.artist != previous.artist || playbackSessionChanged {
            let exactStart = sessionStartOffset(for: detected, recordingStartedAt: started)
            let boundary = max(previous.start, exactStart.map { max(0, $0) } ?? observed)
            let previousWasComplete = currentTrackStartedNearBeginning && Self.isAtTrackEnd(lastDetectedTrack)
            if activeMode == .single {
                if previousWasComplete {
                    singleEndTime = boundary
                    discardUnfinishedTail = false
                    status = "当前歌曲已播完，正在自动保存 \(previous.title)…"
                    interruptCapture()
                    return
                }

                // 开始录制时正在播放的半截歌只是预备缓冲。用户随后点选
                // 任意目标歌曲时，丢弃前段并把新歌作为本次单曲候选。
                let newStart = exactStart.map { max(0, $0) } ?? observed
                trackSegments = [TrackSegment(
                    title: detected.title,
                    artist: detected.artist,
                    album: detected.album,
                    start: newStart
                )]
                title = detected.title
                artist = detected.artist
                album = detected.album
                lastDetectedTrack = detected
                singleTrackDuration = detected.duration
                singleEndTime = nil
                discardUnfinishedTail = false
                currentTrackStartedNearBeginning = (exactStart ?? -.infinity) >= 0
                lastProgressAdvanceAt = nil
                status = currentTrackStartedNearBeginning
                    ? "前面的半截歌已忽略，开始录制：\(detected.title) — \(detected.artist)"
                    : "前面的半截歌已忽略；正在等待一次发生在录音启动后的完整重播"
                return
            }
            if previousWasComplete {
                completedTracks.append(CompletedTrack(segment: previous, end: boundary))
            }
            trackSegments.append(TrackSegment(
                title: detected.title,
                artist: detected.artist,
                album: detected.album,
                start: boundary
            ))
            title = detected.title
            artist = detected.artist
            album = detected.album
            lastDetectedTrack = detected
            lastProgressAdvanceAt = now
            currentTrackStartedNearBeginning = (exactStart ?? -.infinity) >= 0
            status = previousWasComplete
                ? "上一首已完整记录，正在继续：\(detected.title) — \(detected.artist)"
                : "上一首未播完，已标记丢弃；正在继续：\(detected.title) — \(detected.artist)"
            return
        }

        let playbackRate = cachedNowPlaying?.playbackRate ?? 0
        if playbackRate <= 0.01, !Self.isAtTrackEnd(detected) {
            // 真正的暂停不是歌曲结束：持续等待恢复，既不结束连续任务，
            // 也不把暂停误判成“播放器停止”。
            lastDetectedTrack = detected
            lastProgressAdvanceAt = nil
            status = "播放已暂停，录音任务正在等待恢复…"
            return
        }

        if let elapsed = detected.elapsed,
           let previousElapsed = lastDetectedTrack?.elapsed {
            if elapsed > previousElapsed + 3 {
                currentTrackStartedNearBeginning = false
            }
            if elapsed > previousElapsed + 0.1 || elapsed < previousElapsed - 0.5 {
                lastProgressAdvanceAt = now
            }
        }
        lastDetectedTrack = detected

        if activeMode == .single,
           currentTrackStartedNearBeginning,
           Self.hasReachedTrackEnd(detected) {
            singleEndTime = observed
            discardUnfinishedTail = false
            status = "已到总时长，正在自动保存 \(detected.title)…"
            interruptCapture()
            return
        }

        if let lastProgressAdvanceAt,
           now.timeIntervalSince(lastProgressAdvanceAt) >= 3 {
            if activeMode == .single {
                discardUnfinishedTail = !currentTrackStartedNearBeginning || !Self.isAtTrackEnd(detected)
                if !discardUnfinishedTail { singleEndTime = observed }
            } else {
                completeContinuousTailIfAtEnd(observed: observed)
            }
            status = currentTrackStartedNearBeginning && Self.isAtTrackEnd(detected)
                ? "播放已结束，正在自动保存完整歌曲…"
                : "播放中断，正在丢弃未播完的最后一首并保存之前的歌曲…"
            interruptCapture()
        }
    }

    private func completeContinuousTailIfAtEnd(observed: TimeInterval) {
        guard activeMode == .continuous,
              currentTrackStartedNearBeginning,
              Self.isAtTrackEnd(lastDetectedTrack),
              let segment = trackSegments.last,
              !completedTracks.contains(where: { $0.segment.start == segment.start }) else { return }
        completedTracks.append(CompletedTrack(segment: segment, end: max(segment.start, observed)))
    }

    private func sessionStartOffset(
        for track: DetectedTrack,
        recordingStartedAt: Date
    ) -> TimeInterval? {
        guard let playbackStartedAt = track.playbackStartedAt else { return nil }
        return playbackStartedAt - recordingStartedAt.timeIntervalSince1970
    }

    nonisolated private static func playbackSessionChanged(
        from previous: DetectedTrack?,
        to current: DetectedTrack
    ) -> Bool {
        guard let oldStart = previous?.playbackStartedAt,
              let newStart = current.playbackStartedAt,
              abs(newStart - oldStart) >= 0.75 else { return false }
        // 暂停后恢复也会刷新 MediaRemote 的时间锚点，但位置锚点仍是
        // 暂停处；只有位置锚点重新归零才代表同一首歌真正从头重播。
        return (current.positionAnchorElapsed ?? .infinity) <= 0.25
    }

    nonisolated private static func isAtTrackEnd(_ track: DetectedTrack?) -> Bool {
        guard let elapsed = track?.elapsed,
              let duration = track?.duration,
              duration > 0 else { return false }
        return elapsed >= duration - 2.0
    }

    nonisolated private static func hasReachedTrackEnd(_ track: DetectedTrack) -> Bool {
        guard let elapsed = track.elapsed,
              let duration = track.duration,
              duration > 0 else { return false }
        return elapsed >= duration - 0.25
    }

    private func splitRecordedSession(
        _ session: URL,
        deleteSourceAfterSuccess: Bool = true
    ) {
        guard let ffmpeg = ffmpegURL() else {
            status = "录制完成，但找不到 FFmpeg；会话文件已保留：\(session.lastPathComponent)"
            return
        }
        let folder = URL(fileURLWithPath: outputFolder, isDirectory: true)
        var segments = trackSegments
        if segments.isEmpty {
            segments = [TrackSegment(title: title, artist: artist, album: album, start: 0)]
        }
        if activeMode == .single, segments.count > 1 {
            segments = [segments[0]]
        } else if activeMode == .continuous {
            if completedTracks.isEmpty {
                try? FileManager.default.removeItem(at: session)
                isFinishing = false
                lastOutput = nil
                status = "没有完整播放的歌曲，未完成片段已丢弃"
                return
            }
            segments = completedTracks.map(\.segment)
        }

        let specs = segments.enumerated().map { index, segment in
            let nextStart: TimeInterval? = {
                if activeMode == .single { return singleEndTime }
                return index < completedTracks.count ? completedTracks[index].end : nil
            }()
            let output: URL
            if index == 0, segment.start == 0, let intendedOutput {
                output = intendedOutput
            } else {
                output = uniqueURL(
                    in: folder,
                    baseName: safeFilename(segment.title.isEmpty ? "曲目-\(index + 1)" : segment.title),
                    extension: format.fileExtension
                )
            }
            return SplitSpec(
                source: session,
                output: output,
                start: segment.start,
                duration: nextStart.map { max(0.05, $0 - segment.start) },
                title: segment.title,
                artist: segment.artist,
                album: segment.album,
                codecArguments: codecArguments(for: format),
                trimLeadingSilence: index == 0
            )
        }

        isFinishing = true
        status = "录制完成，正在生成 \(specs.count) 个分轨文件…"
        Task.detached {
            do {
                for spec in specs {
                    try Self.runSplit(ffmpeg: ffmpeg, spec: spec)
                }
                if deleteSourceAfterSuccess {
                    try FileManager.default.removeItem(at: session)
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isFinishing = false
                    self.lastOutput = specs.first?.output
                    self.status = specs.count == 1
                        ? "自动保存完成：\(specs[0].output.lastPathComponent)"
                        : "连续录制完成：已保存 \(specs.count) 首完整歌曲"
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isFinishing = false
                    self.status = "分轨失败：\(error.localizedDescription)；原始会话文件已保留"
                }
            }
        }
    }

    nonisolated private static func runSplit(ffmpeg: URL, spec: SplitSpec) throws {
        let task = Process()
        let errorPipe = Pipe()
        task.executableURL = ffmpeg
        var arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-ss", String(format: "%.3f", spec.start),
            "-i", spec.source.path
        ]
        if let duration = spec.duration {
            arguments += ["-t", String(format: "%.3f", duration)]
        }
        if spec.trimLeadingSilence {
            arguments += [
                "-af",
                "silenceremove=start_periods=1:start_duration=0.05:start_threshold=-70dB"
            ]
        }
        arguments += [
            "-map_metadata", "-1",
            "-metadata", "title=\(spec.title)",
            "-metadata", "artist=\(spec.artist)",
            "-metadata", "album=\(spec.album)"
        ]
        arguments += spec.codecArguments
        arguments += [spec.output.path]
        task.arguments = arguments
        task.standardError = errorPipe
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
            throw NSError(
                domain: "QishuiCapture.Split",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "FFmpeg 转换失败" : message]
            )
        }
    }

    private func captureToolURL() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let bundledHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/录音核心.app/Contents/MacOS/qishui-capture")
        if FileManager.default.isExecutableFile(atPath: bundledHelper.path) { return bundledHelper }

        let sibling = executable.deletingLastPathComponent().appendingPathComponent("qishui-capture")
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }

        let developmentSibling = executable.deletingLastPathComponent().appendingPathComponent("qishui-capture")
        return FileManager.default.isExecutableFile(atPath: developmentSibling.path) ? developmentSibling : nil
    }

    private func ffmpegURL() -> URL? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    private func ffprobeURL() -> URL? {
        let candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    private func codecArguments(for format: ExportFormat) -> [String] {
        switch format {
        case .flac: ["-c:a", "flac", "-compression_level", "8"]
        case .wav: ["-c:a", "pcm_s24le", "-ar", "48000", "-ac", "2"]
        case .mp3: ["-c:a", "libmp3lame", "-b:a", "320k"]
        case .alac: ["-c:a", "alac"]
        case .aac: ["-c:a", "aac", "-b:a", "256k"]
        }
    }

    private func readMetadata(from url: URL) {
        guard let ffprobe = ffprobeURL() else {
            conversionStatus = "找不到 FFprobe，仍可转换但无法读取标签"
            return
        }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = ffprobe
        task.arguments = [
            "-v", "error", "-show_entries", "format_tags=title,artist,album",
            "-of", "json", url.path
        ]
        task.standardOutput = pipe
        task.terminationHandler = { [weak self] finishedTask in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if finishedTask.terminationStatus == 0,
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let format = object["format"] as? [String: Any],
                   let tags = format["tags"] as? [String: Any] {
                    let lowerTags = Dictionary(uniqueKeysWithValues: tags.map { ($0.key.lowercased(), $0.value) })
                    if let value = lowerTags["title"] as? String, !value.isEmpty { self.title = value }
                    if let value = lowerTags["artist"] as? String, !value.isEmpty { self.artist = value }
                    if let value = lowerTags["album"] as? String, !value.isEmpty { self.album = value }
                    self.conversionStatus = "标签已读取，可选择格式并转换"
                } else {
                    self.conversionStatus = "未读到标签，仍可直接转换"
                }
            }
        }
        try? task.run()
    }

    private func lookupAlbum(title: String, artist: String) {
        guard album.isEmpty else { return }
        Task {
            var components = URLComponents(string: "https://itunes.apple.com/search")
            components?.queryItems = [
                URLQueryItem(name: "term", value: "\(title) \(artist)"),
                URLQueryItem(name: "entity", value: "song"),
                URLQueryItem(name: "country", value: "CN"),
                URLQueryItem(name: "limit", value: "10")
            ]
            guard let url = components?.url,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = object["results"] as? [[String: Any]] else { return }
            let normalizedTitle = title.lowercased().replacingOccurrences(of: " ", with: "")
            let match = results.first { result in
                guard let candidate = result["trackName"] as? String else { return false }
                return candidate.lowercased().replacingOccurrences(of: " ", with: "").contains(normalizedTitle)
            }
            if let collection = match?["collectionName"] as? String, !collection.isEmpty {
                album = collection
                status = "已读取歌名、歌手，并补全专辑"
            }
        }
    }

    nonisolated private static func currentTrack(from appElement: AXUIElement) -> DetectedTrack? {
        guard let windows = attribute(appElement, kAXWindowsAttribute as CFString) as? [AXUIElement] else { return nil }
        for window in windows {
            var visited = 0
            if let match = findProgressElement(window, depth: 0, visited: &visited) {
                var scope: AXUIElement? = match.element
                for _ in 0..<8 {
                    guard let currentScope = scope else { break }
                    var linkVisited = 0
                    var linkTexts: [String] = []
                    collectLinkTexts(
                        currentScope,
                        depth: 0,
                        visited: &linkVisited,
                        values: &linkTexts
                    )
                    if linkTexts.count >= 2 {
                        return DetectedTrack(
                            title: linkTexts[0],
                            artist: linkTexts[1],
                            album: "",
                            elapsed: match.progress.elapsed,
                            duration: match.progress.duration
                        )
                    }
                    if let parent = attribute(currentScope, kAXParentAttribute as CFString),
                       CFGetTypeID(parent) == AXUIElementGetTypeID() {
                        scope = (parent as! AXUIElement)
                    } else {
                        scope = nil
                    }
                }
            }

            visited = 0
            if let fallback = findSeparateClockTrackContainer(window, depth: 0, visited: &visited) {
                return fallback
            }
        }
        return nil
    }

    nonisolated private static func findProgressElement(
        _ element: AXUIElement,
        depth: Int,
        visited: inout Int
    ) -> (element: AXUIElement, progress: (elapsed: TimeInterval, duration: TimeInterval))? {
        guard depth < 20, visited < 6000 else { return nil }
        visited += 1
        if let text = elementText(element), let progress = extractProgress(text) {
            return (element, progress)
        }
        if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in children {
                if let result = findProgressElement(child, depth: depth + 1, visited: &visited) {
                    return result
                }
            }
        }
        return nil
    }

    nonisolated private static func collectLinkTexts(
        _ element: AXUIElement,
        depth: Int,
        visited: inout Int,
        values: inout [String]
    ) {
        guard depth < 10, visited < 1000 else { return }
        visited += 1
        if attribute(element, kAXRoleAttribute as CFString) as? String == "AXLink",
           let text = elementText(element),
           !text.isEmpty,
           !values.contains(text) {
            values.append(text)
        }
        if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in children {
                collectLinkTexts(child, depth: depth + 1, visited: &visited, values: &values)
            }
        }
    }

    nonisolated private static func findSeparateClockTrackContainer(
        _ element: AXUIElement,
        depth: Int,
        visited: inout Int
    ) -> DetectedTrack? {
        guard depth < 20, visited < 6000 else { return nil }
        visited += 1
        if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in children {
                if let match = findSeparateClockTrackContainer(child, depth: depth + 1, visited: &visited) {
                    return match
                }
            }
        }
        var subtreeVisited = 0
        var clocks: [String] = []
        collectClockLabels(element, depth: 0, visited: &subtreeVisited, values: &clocks)
        guard let progress = progressFromSeparateClockLabels(clocks) else { return nil }
        subtreeVisited = 0
        var links: [String] = []
        collectLinkTexts(element, depth: 0, visited: &subtreeVisited, values: &links)
        guard links.count >= 2 else { return nil }
        return DetectedTrack(
            title: links[0],
            artist: links[1],
            album: "",
            elapsed: progress.elapsed,
            duration: progress.duration
        )
    }

    nonisolated private static func collectClockLabels(
        _ element: AXUIElement,
        depth: Int,
        visited: inout Int,
        values: inout [String]
    ) {
        guard depth < 6, visited < 500 else { return }
        visited += 1
        if let text = elementText(element),
           text.range(of: #"^\s*\d{1,2}:\d{2}\s*$"#, options: .regularExpression) != nil,
           !values.contains(text) {
            values.append(text)
        }
        if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
            for child in children {
                collectClockLabels(child, depth: depth + 1, visited: &visited, values: &values)
            }
        }
    }

    nonisolated private static func extractProgress(
        _ text: String
    ) -> (elapsed: TimeInterval, duration: TimeInterval)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(\d{1,2}:\d{2})\s*/\s*(\d{1,2}:\d{2})"#
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let elapsedRange = Range(match.range(at: 1), in: text),
              let durationRange = Range(match.range(at: 2), in: text),
              let elapsed = parseClock(String(text[elapsedRange])),
              let duration = parseClock(String(text[durationRange])) else { return nil }
        return (elapsed, duration)
    }

    nonisolated private static func parseProgress(_ text: String) -> (elapsed: TimeInterval, duration: TimeInterval)? {
        let halves = text.split(separator: "/")
        guard halves.count >= 2,
              let elapsed = parseClock(String(halves[0])),
              let duration = parseClock(String(halves[1])) else { return nil }
        return (elapsed, duration)
    }

    nonisolated private static func progressFromSeparateClockLabels(
        _ values: [String]
    ) -> (elapsed: TimeInterval, duration: TimeInterval)? {
        var clocks: [TimeInterval] = []
        for value in values {
            guard let clock = parseClock(value), !clocks.contains(clock) else { continue }
            clocks.append(clock)
        }
        guard clocks.count >= 2 else { return nil }
        for elapsedIndex in 0..<(clocks.count - 1) {
            for durationIndex in (elapsedIndex + 1)..<clocks.count
            where clocks[durationIndex] > clocks[elapsedIndex] {
                return (clocks[elapsedIndex], clocks[durationIndex])
            }
        }
        return nil
    }

    nonisolated private static func parseClock(_ text: String) -> TimeInterval? {
        let components = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard components.count == 2,
              let minutes = Double(components[0]),
              let seconds = Double(components[1]) else { return nil }
        return minutes * 60 + seconds
    }

    nonisolated private static func clockText(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    nonisolated private static func elementText(_ element: AXUIElement) -> String? {
        let keys: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXValueAttribute as CFString,
            kAXDescriptionAttribute as CFString
        ]
        for key in keys {
            if let value = attribute(element, key) as? String,
               !value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            }
        }
        return nil
    }

    nonisolated private static func attribute(_ element: AXUIElement, _ key: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key, &value) == .success ? value : nil
    }

    nonisolated private static func pointAttribute(_ element: AXUIElement, _ key: CFString) -> CGPoint? {
        guard let raw = attribute(element, key), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
    }

    nonisolated private static func sizeAttribute(_ element: AXUIElement, _ key: CFString) -> CGSize? {
        guard let raw = attribute(element, key), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &size) ? size : nil
    }

    private func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "汽水录音-\(formatter.string(from: Date()))"
    }

    private func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let components = value.components(separatedBy: invalid)
        let result = components.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? defaultFilename() : result
    }

    private func uniqueURL(in folder: URL, baseName: String, extension ext: String) -> URL {
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(ext)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName)-\(number)").appendingPathExtension(ext)
            number += 1
        }
        return candidate
    }

    nonisolated private static func lastDBFS(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: "(-?\\d+(?:\\.\\d+)?)\\s*dBFS") else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[valueRange])
    }
}

private struct RecorderView: View {
    @StateObject private var model = RecorderModel()
    @State private var keepWindowVisible = true
    @State private var isConversionDropTarget = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("录音机")
                    .font(.system(size: 26, weight: .semibold))
                Text("捕获应用解码后的数字音频，不使用麦克风")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Toggle("所有桌面置顶", isOn: $keepWindowVisible)
                        .toggleStyle(.switch)
                        .onChange(of: keepWindowVisible) { _, enabled in configureWindow(enabled) }
                    Spacer(minLength: 30)
                    Toggle("静音监听 · 仍然录音", isOn: $model.mutePlayback)
                        .toggleStyle(.switch)
                        .disabled(model.isFinishing || model.monitorPending || (model.isRecording && !model.captureReady))
                        .onChange(of: model.mutePlayback) { _, _ in model.changeMonitoring() }
                }.padding(.bottom, 6)
                Text(model.monitorStatus).font(.caption).foregroundStyle(.secondary)
                Text("不要点播放器自己的静音或把它的音量调到零。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("目标应用")
                    HStack {
                        Picker("", selection: $model.targetApp) {
                            ForEach(model.detectedPlayers) { application in
                                Text("\(application.name)  ·  \(application.bundleIdentifier)")
                                    .tag(application.bundleIdentifier)
                            }
                        }
                        .labelsHidden()
                        Button("刷新") { model.refreshPlayers() }
                        Button(model.isReadingTrack ? "正在读取…" : "读取当前歌曲") { model.readCurrentTrack() }
                            .disabled(model.isReadingTrack || model.isRecording || model.isFinishing)
                    }
                }
                GridRow {
                    Text("歌曲")
                    TextField("可留空，自动用时间命名", text: $model.title)
                }
                GridRow {
                    Text("歌手")
                    TextField("可留空", text: $model.artist)
                }
                GridRow {
                    Text("专辑")
                    TextField("可留空", text: $model.album)
                }
                GridRow {
                    Text("录制模式")
                    HStack {
                        Picker("", selection: $model.recordingMode) {
                            ForEach(RecordingMode.userChoices) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                        Text(model.recordingMode.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("格式")
                    HStack {
                        Picker("", selection: $model.format) {
                            ForEach(ExportFormat.allCases) { format in
                                Text(format.rawValue).tag(format)
                            }
                        }
                        .labelsHidden()
                        Text(model.format.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("保存到")
                    HStack {
                        TextField("文件夹", text: $model.outputFolder)
                        Button("选择…") { model.chooseFolder() }
                    }
                }
            }
            .disabled(model.isRecording || model.isFinishing)

            VStack(spacing: 8) {
                ProgressView(value: model.levelProgress)
                    .tint(model.levelDB > -6 ? .orange : model.levelDB > -60 ? .green : .gray)
                    .animation(.linear(duration: 0.2), value: model.levelProgress)
                HStack {
                    Text("音频电平")
                    Spacer()
                    Text(model.isRecording ? String(format: "%.1f dBFS", model.levelDB) : "— dBFS")
                        .monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    loudnessValue("当前 · 近 3 秒", model.shortLUFS)
                    loudnessValue("本首累计 · 估算", model.integratedLUFS)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("成品参考").font(.caption).foregroundStyle(.secondary)
                        Text("−14 LUFS").font(.headline.monospacedDigit())
                    }
                    Spacer()
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(Color.green).frame(width: geometry.size.width * max(0, min(1, ((model.shortLUFS ?? -40) + 40) / 40)))
                        Rectangle().fill(Color.primary).frame(width: 2).offset(x: geometry.size.width * 0.65)
                    }
                }.frame(height: 8)
                Text(model.loudnessStatus + " · 参考线不代表已自动调音")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.signalWarning.isEmpty {
                    Text(model.signalWarning).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
            }

            HStack(spacing: 12) {
                Button {
                    model.start()
                } label: {
                    Label("开始录制", systemImage: "record.circle")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.isRecording || model.isFinishing)

                Button {
                    model.stop()
                } label: {
                    Label(
                        model.recordingMode == .single ? "取消这一首" : "停止连续录制",
                        systemImage: "stop.circle"
                    )
                        .frame(minWidth: 120)
                }
                .buttonStyle(.bordered)
                .disabled(!model.isRecording)

                Button("查看文件") { model.revealOutput() }
                    .disabled(model.isRecording || model.isFinishing)
            }

            GroupBox("转换已有音频") {
                VStack(spacing: 10) {
                    HStack {
                        TextField("选择 FLAC、WAV、MP3、M4A 等音频", text: $model.conversionInput)
                            .disabled(true)
                        Button("选择文件…") { model.chooseConversionInput() }
                    }
                    HStack {
                        Picker("转换为", selection: $model.conversionFormat) {
                            ForEach(ExportFormat.allCases) { format in
                                Text(format.rawValue).tag(format)
                            }
                        }
                        .frame(width: 180)
                        Button("开始转换") { model.convertExistingFile() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.conversionInput.isEmpty || model.isConverting)
                        Spacer()
                        Text(model.conversionStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(4)
            }
            .overlay {
                if isConversionDropTarget {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.blue, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.acceptConversionDrop(urls)
            } isTargeted: { targeted in
                isConversionDropTarget = targeted
            }

            Text(model.recordingMode == .single
                 ? "单曲：开始录制 → 重新点击歌曲从头播放；到总时长自动保存"
                 : "连续：完整播完的歌自动保存；停止时未播完的最后一首自动丢弃")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 610)
        .onAppear {
            configureWindow(keepWindowVisible)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                configureWindow(keepWindowVisible)
            }
        }
    }

    private func loudnessValue(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.1f LUFS", $0) } ?? "— LUFS")
                .font(.headline.monospacedDigit())
        }
    }

    private func configureWindow(_ enabled: Bool) {
        let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        for window in NSApplication.shared.windows where window.title == "录音机" {
            window.level = enabled ? .floating : .normal
            if enabled {
                window.collectionBehavior.formUnion(behavior)
            } else {
                window.collectionBehavior.subtract(behavior)
            }
        }
    }
}

@main
private struct QishuiCaptureGUIApp: App {
    var body: some Scene {
        WindowGroup {
            RecorderView()
        }
        .windowResizability(.contentSize)
    }
}
