import Darwin
import Dispatch
import Foundation
import AppKit
import ObjectiveC

typealias RawFunction = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Void
typealias PIDBlock = @convention(block) (pid_t) -> Void
typealias InfoBlock = @convention(block) (CFDictionary?) -> Void

final class ResultBox {
    var processIdentifier: pid_t = -1
    var dictionary: NSDictionary?
}

let parentPID = CommandLine.arguments.count > 1 ? pid_t(CommandLine.arguments[1]) ?? -1 : -1
let targetBundleID = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
let framework = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
guard let handle = dlopen(framework, RTLD_NOW | RTLD_LOCAL),
      let pidSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID"),
      let infoSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else { exit(2) }

let pidFunction = unsafeBitCast(pidSymbol, to: RawFunction.self)
let infoFunction = unsafeBitCast(infoSymbol, to: RawFunction.self)
let callbackQueue = DispatchQueue.global(qos: .userInitiated)
let queuePointer = Unmanaged.passUnretained(callbackQueue as AnyObject).toOpaque()

// The global Now Playing owner changes when a browser/video starts. Address the
// selected application's local default player instead. All selectors are checked
// because MediaRemote is a private, version-dependent interface.
func objectCall(_ object: AnyObject, _ name: String) -> AnyObject? {
    let selector = NSSelectorFromString(name)
    guard let method = class_getInstanceMethod(object_getClass(object), selector) else { return nil }
    let invoke = unsafeBitCast(method_getImplementation(method),
        to: (@convention(c) (AnyObject, Selector) -> AnyObject?).self)
    return invoke(object, selector)
}

func makeTargetRequest(_ pid: pid_t) -> AnyObject? {
    guard let originClass = NSClassFromString("MROrigin"),
          let playerClass = NSClassFromString("MRPlayer"),
          let pathClass = NSClassFromString("MRPlayerPath"),
          let clientClass = NSClassFromString("MRClient"),
          let requestClass = NSClassFromString("MRNowPlayingRequest"),
          let origin = objectCall(originClass, "localOrigin"),
          let player = objectCall(playerClass, "defaultPlayer"),
          let allocatedPath = objectCall(pathClass, "alloc"),
          let allocatedClient = objectCall(clientClass, "alloc") else { return nil }
    let clientSelector = NSSelectorFromString("initWithProcessIdentifier:bundleIdentifier:")
    guard let clientMethod = class_getInstanceMethod(clientClass, clientSelector) else { return nil }
    let createClient = unsafeBitCast(method_getImplementation(clientMethod),
        to: (@convention(c) (AnyObject, Selector, pid_t, AnyObject?) -> AnyObject).self)
    let client = createClient(allocatedClient, clientSelector, pid, nil)
    let pathSelector = NSSelectorFromString("initWithOrigin:client:player:")
    guard let pathMethod = class_getInstanceMethod(pathClass, pathSelector) else { return nil }
    let createPath = unsafeBitCast(method_getImplementation(pathMethod),
        to: (@convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject) -> AnyObject).self)
    let path = createPath(allocatedPath, pathSelector, origin, client, player)
    guard let allocatedRequest = objectCall(requestClass, "alloc") as? NSObject,
          allocatedRequest.responds(to: NSSelectorFromString("initWithPlayerPath:")),
          let request = allocatedRequest.perform(NSSelectorFromString("initWithPlayerPath:"), with: path)?.takeUnretainedValue()
    else { return nil }
    return request
}

var targetRequest: AnyObject?
var targetRequestPID: pid_t = -1

func targetedQuery(_ bundleID: String) -> (pid_t, NSDictionary)? {
    guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else { return nil }
    if targetRequestPID != app.processIdentifier {
        targetRequest = makeTargetRequest(app.processIdentifier)
        targetRequestPID = app.processIdentifier
    }
    guard let request = targetRequest else { return nil }
    let selector = NSSelectorFromString("requestNowPlayingInfoOnQueue:completion:")
    guard let method = class_getInstanceMethod(object_getClass(request), selector) else { return nil }
    let result = ResultBox()
    let completed = DispatchSemaphore(value: 0)
    let callback: @convention(block) (AnyObject?, AnyObject?) -> Void = { value, error in
        if error == nil { result.dictionary = (value as? NSDictionary)?.copy() as? NSDictionary }
        completed.signal()
    }
    let invoke = unsafeBitCast(method_getImplementation(method),
        to: (@convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void).self)
    invoke(request, selector, callbackQueue, unsafeBitCast(callback, to: AnyObject.self))
    guard completed.wait(timeout: .now() + 1) == .success,
          let dictionary = result.dictionary else { return nil }
    return (app.processIdentifier, dictionary)
}

func query() -> [String: Any]? {
    let result = ResultBox()
    if let targetBundleID {
        guard let (pid, dictionary) = targetedQuery(targetBundleID) else { return nil }
        result.processIdentifier = pid
        result.dictionary = dictionary
    } else {
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
    }

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
