import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

struct ProcessTapCaptureResult {
    let frames: AVAudioFramePosition
    let sampleRate: Double
    let heardSound: Bool
}

enum ProcessTapError: Error, LocalizedError {
    case targetProcessNotFound(String)
    case coreAudio(String, OSStatus)
    case noInputStream
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .targetProcessNotFound(let bundleID):
            return "播放器尚未建立音频进程：\(bundleID)"
        case .coreAudio(let operation, let status):
            return "\(operation)失败（Core Audio \(Self.statusText(status))）"
        case .noInputStream:
            return "录音设备没有生成可读取的音频流"
        case .unsupportedFormat:
            return "播放器输出了暂不支持的音频格式"
        }
    }

    private static func statusText(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        if bytes.allSatisfy({ (32...126).contains($0) }) {
            return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")'"
        }
        return String(status)
    }
}

private func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

private func requireNoError(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw ProcessTapError.coreAudio(operation, status) }
}

private func processObjects(matching bundleID: String) throws -> [AudioObjectID] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var listAddress = propertyAddress(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    try requireNoError(
        AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size),
        "读取音频进程列表"
    )
    var objects = [AudioObjectID](
        repeating: kAudioObjectUnknown,
        count: Int(size) / MemoryLayout<AudioObjectID>.stride
    )
    try requireNoError(
        AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &objects),
        "读取音频进程列表"
    )

    return objects.filter { objectID in
        var address = propertyAddress(kAudioProcessPropertyBundleID)
        var value: CFString = "" as CFString
        var valueSize = UInt32(MemoryLayout<CFString>.stride)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &valueSize, $0)
        }
        guard status == noErr else { return false }
        let candidate = value as String
        return candidate == bundleID || candidate.hasPrefix(bundleID + ".")
    }
}

private func inputStreamFormat(for deviceID: AudioObjectID) throws -> AudioStreamBasicDescription {
    var streamsAddress = propertyAddress(kAudioDevicePropertyStreams)
    var size: UInt32 = 0
    try requireNoError(
        AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &size),
        "读取录音设备音频流"
    )
    var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
    try requireNoError(
        AudioObjectGetPropertyData(deviceID, &streamsAddress, 0, nil, &size, &streams),
        "读取录音设备音频流"
    )

    for streamID in streams {
        var directionAddress = propertyAddress(kAudioStreamPropertyDirection)
        var direction: UInt32 = 0
        var directionSize = UInt32(MemoryLayout<UInt32>.stride)
        guard AudioObjectGetPropertyData(
            streamID, &directionAddress, 0, nil, &directionSize, &direction
        ) == noErr, direction == 1 else { continue }

        var formatAddress = propertyAddress(kAudioStreamPropertyVirtualFormat)
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
        try requireNoError(
            AudioObjectGetPropertyData(streamID, &formatAddress, 0, nil, &formatSize, &format),
            "读取录音设备格式"
        )
        return format
    }
    throw ProcessTapError.noInputStream
}

private func waitForInputStreamFormat(for deviceID: AudioObjectID) throws -> AudioStreamBasicDescription {
    var lastError: Error = ProcessTapError.noInputStream
    for _ in 0..<40 {
        do {
            return try inputStreamFormat(for: deviceID)
        } catch {
            lastError = error
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    throw lastError
}

private func tapRecorderIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let recorder = Unmanaged<ProcessTapRecorder>.fromOpaque(clientData).takeUnretainedValue()
    return recorder.consume(inputData)
}

final class ProcessTapRecorder: @unchecked Sendable {
    private let targetBundleID: String
    private let outputURL: URL
    private let thresholdDB: Double
    private let silenceSeconds: Double
    private let audioSeconds: Double?
    private let lock = NSLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFile: ExtAudioFileRef?
    private var streamFormat = AudioStreamBasicDescription()
    private var totalFrames: AVAudioFramePosition = 0
    private var silentFrames: AVAudioFramePosition = 0
    private var detectedSound = false
    private var firstSoundFrame: AVAudioFramePosition?
    private var requestedStop = false
    private var lastMeterPrint = Date.distantPast
    private var started = false

    var onAutomaticStop: (@Sendable () -> Void)?

    init(
        targetBundleID: String,
        outputURL: URL,
        thresholdDB: Double,
        silenceSeconds: Double,
        audioSeconds: Double?
    ) {
        self.targetBundleID = targetBundleID
        self.outputURL = outputURL
        self.thresholdDB = thresholdDB
        self.silenceSeconds = silenceSeconds
        self.audioSeconds = audioSeconds
    }

    func start() throws {
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let matchingProcesses = try processObjects(matching: targetBundleID)
            if matchingProcesses.isEmpty, #unavailable(macOS 26.0) {
                throw ProcessTapError.targetProcessNotFound(targetBundleID)
            }

            let description = CATapDescription()
            description.name = "录音机 · \(targetBundleID)"
            description.processes = matchingProcesses
            description.isPrivate = true
            description.muteBehavior = .unmuted
            description.isMixdown = true
            description.isMono = false
            if #available(macOS 26.0, *) {
                description.bundleIDs = [targetBundleID, targetBundleID + ".helper"]
                description.isProcessRestoreEnabled = true
            }
            try requireNoError(
                AudioHardwareCreateProcessTap(description, &tapID),
                "创建应用音频录制通道"
            )

            var uidAddress = propertyAddress(kAudioTapPropertyUID)
            var tapUID: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.stride)
            try requireNoError(
                withUnsafeMutablePointer(to: &tapUID) {
                    AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil, &uidSize, $0)
                },
                "读取录音通道标识"
            )

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "录音机临时音频设备",
                kAudioAggregateDeviceUIDKey: "com.sunyiting.recorder.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true
            ]
            try requireNoError(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &aggregateDeviceID
                ),
                "创建临时录音设备"
            )

            var tapListAddress = propertyAddress(kAudioAggregateDevicePropertyTapList)
            var tapList: CFArray? = [tapUID] as CFArray
            let tapListSize = UInt32(MemoryLayout<CFString>.stride)
            try requireNoError(
                withUnsafeMutablePointer(to: &tapList) {
                    AudioObjectSetPropertyData(
                        aggregateDeviceID,
                        &tapListAddress,
                        0,
                        nil,
                        tapListSize,
                        $0
                    )
                },
                "连接应用音频录制通道"
            )

            streamFormat = try waitForInputStreamFormat(for: aggregateDeviceID)
            guard streamFormat.mFormatID == kAudioFormatLinearPCM,
                  streamFormat.mBitsPerChannel == 32 else {
                throw ProcessTapError.unsupportedFormat
            }

            var format = streamFormat
            try requireNoError(
                ExtAudioFileCreateWithURL(
                    outputURL as CFURL,
                    kAudioFileWAVEType,
                    &format,
                    nil,
                    AudioFileFlags.eraseFile.rawValue,
                    &audioFile
                ),
                "创建临时无损录音文件"
            )

            var createdIOProc: AudioDeviceIOProcID?
            try requireNoError(
                AudioDeviceCreateIOProcID(
                    aggregateDeviceID,
                    tapRecorderIOProc,
                    Unmanaged.passUnretained(self).toOpaque(),
                    &createdIOProc
                ),
                "创建音频读取任务"
            )
            ioProcID = createdIOProc
            try requireNoError(
                AudioDeviceStart(aggregateDeviceID, createdIOProc),
                "启动系统音频录制"
            )
            started = true
        } catch {
            cleanup()
            throw error
        }
    }

    fileprivate func consume(_ inputData: UnsafePointer<AudioBufferList>) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }

        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard let first = buffers.first,
              first.mDataByteSize > 0,
              streamFormat.mBytesPerFrame > 0 else { return noErr }
        let frames = first.mDataByteSize / streamFormat.mBytesPerFrame
        guard frames > 0 else { return noErr }

        if let audioFile {
            let status = ExtAudioFileWriteAsync(audioFile, frames, inputData)
            if status != noErr { return status }
        }
        totalFrames += AVAudioFramePosition(frames)

        let decibels = meterDB(in: buffers)
        if decibels > thresholdDB {
            if !detectedSound {
                firstSoundFrame = totalFrames - AVAudioFramePosition(frames)
            }
            detectedSound = true
            silentFrames = 0
        } else if detectedSound {
            silentFrames += AVAudioFramePosition(frames)
        }

        if Date().timeIntervalSince(lastMeterPrint) >= 0.5 {
            let elapsed = streamFormat.mSampleRate > 0
                ? Double(totalFrames) / streamFormat.mSampleRate
                : 0
            let line = String(format: "\r录制中 %6.1f 秒 | %6.1f dBFS", elapsed, decibels)
            FileHandle.standardError.write(Data(line.utf8))
            lastMeterPrint = Date()
        }

        if detectedSound,
           silenceSeconds > 0,
           streamFormat.mSampleRate > 0,
           Double(silentFrames) / streamFormat.mSampleRate >= silenceSeconds {
            requestAutomaticStop()
        }
        if let audioSeconds,
           let firstSoundFrame,
           streamFormat.mSampleRate > 0,
           Double(totalFrames - firstSoundFrame) / streamFormat.mSampleRate >= audioSeconds {
            requestAutomaticStop()
        }
        return noErr
    }

    private func meterDB(in buffers: UnsafeMutableAudioBufferListPointer) -> Double {
        guard streamFormat.mFormatID == kAudioFormatLinearPCM,
              streamFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return -160 }
        var sum = 0.0
        var count = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let samples = data.bindMemory(
                to: Float.self,
                capacity: Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
            )
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
            for index in 0..<sampleCount {
                let value = Double(samples[index])
                sum += value * value
            }
            count += sampleCount
        }
        guard count > 0, sum > 0 else { return -160 }
        return 20 * log10(sqrt(sum / Double(count)))
    }

    private func requestAutomaticStop() {
        guard !requestedStop else { return }
        requestedStop = true
        onAutomaticStop?()
    }

    func stop() -> ProcessTapCaptureResult {
        if started, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
            started = false
        }
        if let audioFile {
            ExtAudioFileDispose(audioFile)
            self.audioFile = nil
        }
        let result = ProcessTapCaptureResult(
            frames: totalFrames,
            sampleRate: streamFormat.mSampleRate,
            heardSound: detectedSound
        )
        destroyAudioObjects()
        return result
    }

    private func cleanup() {
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if let audioFile {
            ExtAudioFileDispose(audioFile)
            self.audioFile = nil
        }
        destroyAudioObjects()
    }

    private func destroyAudioObjects() {
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    deinit { cleanup() }
}
