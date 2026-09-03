import Darwin
import Dispatch
import Foundation

typealias RawFunction = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void
typealias PIDBlock = @convention(block) (pid_t) -> Void
typealias InfoBlock = @convention(block) (CFDictionary?) -> Void

final class ResultBox {
    var processIdentifier: pid_t = -1
    var dictionary: NSDictionary?
}

let parentPID = CommandLine.arguments.count > 1 ? pid_t(CommandLine.arguments[1]) ?? -1 : -1
let framework = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
guard let handle = dlopen(framework, RTLD_NOW | RTLD_LOCAL),
      let pidSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID"),
      let infoSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else { exit(2) }

let pidFunction = unsafeBitCast(pidSymbol, to: RawFunction.self)
let infoFunction = unsafeBitCast(infoSymbol, to: RawFunction.self)
let callbackQueue = DispatchQueue.global(qos: .userInitiated)
let queuePointer = Unmanaged.passUnretained(callbackQueue as AnyObject).toOpaque()

func query() -> [String: Any]? {
    let result = ResultBox()
    let pidSemaphore = DispatchSemaphore(value: 0)
    let pidBlock: PIDBlock = { pid in
        result.processIdentifier = pid
        pidSemaphore.signal()
    }
    let pidObject = unsafeBitCast(pidBlock, to: AnyObject.self)
    let retainedPIDBlock = Unmanaged.passRetained(pidObject)
    pidFunction(queuePointer, retainedPIDBlock.toOpaque())
    guard pidSemaphore.wait(timeout: .now() + 1) == .success else { return nil }
    retainedPIDBlock.release()

    let infoSemaphore = DispatchSemaphore(value: 0)
    let infoBlock: InfoBlock = { dictionary in
        if let dictionary { result.dictionary = (dictionary as NSDictionary).copy() as? NSDictionary }
        infoSemaphore.signal()
    }
    let infoObject = unsafeBitCast(infoBlock, to: AnyObject.self)
    let retainedInfoBlock = Unmanaged.passRetained(infoObject)
    infoFunction(queuePointer, retainedInfoBlock.toOpaque())
    guard infoSemaphore.wait(timeout: .now() + 1) == .success else { return nil }
    retainedInfoBlock.release()

    guard let dictionary = result.dictionary,
          let title = dictionary["kMRMediaRemoteNowPlayingInfoTitle"] as? String,
          let duration = (dictionary["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue else {
        return nil
    }
    let baseElapsed = (dictionary["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
    let playbackRate = (dictionary["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
    let timestamp = dictionary["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date
    let playbackStartedAt = timestamp.map {
        $0.timeIntervalSince1970 - baseElapsed
    } ?? 0
    let elapsed: Double
    if playbackRate > 0, let timestamp {
        elapsed = min(duration, max(0, baseElapsed + Date().timeIntervalSince(timestamp) * playbackRate))
    } else {
        elapsed = baseElapsed
    }
    return [
        "processIdentifier": result.processIdentifier,
        "title": title,
        "artist": dictionary["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "",
        "album": dictionary["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? "",
        "elapsed": elapsed,
        "positionAnchorElapsed": baseElapsed,
        "playbackStartedAt": playbackStartedAt,
        "duration": duration,
        "playbackRate": playbackRate
    ]
}

while parentPID <= 0 || kill(parentPID, 0) == 0 {
    if let value = query(),
       let data = try? JSONSerialization.data(withJSONObject: value),
       let line = String(data: data, encoding: .utf8) {
        print(line)
        fflush(stdout)
    }
    Thread.sleep(forTimeInterval: 0.25)
}
