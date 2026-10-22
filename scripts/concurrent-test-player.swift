import AppKit
import AVKit
import MediaPlayer

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let isVideo = CommandLine.arguments[2] == "video"
let title = isVideo ? "Video isolation test" : "Music isolation test"
let start = Date()
let player = AVPlayer(url: URL(fileURLWithPath: CommandLine.arguments[1]))
var window: NSWindow?
if isVideo {
    let view = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    view.player = player
    let w = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    w.title = "录音隔离测试视频"
    w.contentView = view
    w.orderFront(nil)
    window = w
}
MPRemoteCommandCenter.shared().playCommand.addTarget { _ in .success }
MPRemoteCommandCenter.shared().pauseCommand.addTarget { _ in .success }
func publish() {
    let elapsed = player.currentTime().seconds
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
        MPMediaItemPropertyTitle: title,
        MPMediaItemPropertyArtist: "Recorder regression fixture",
        MPMediaItemPropertyAlbumTitle: "Isolation",
        MPMediaItemPropertyPlaybackDuration: 30.0,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.isFinite ? elapsed : 0,
        MPNowPlayingInfoPropertyPlaybackRate: 1.0
    ]
    MPNowPlayingInfoCenter.default().playbackState = .playing
}
player.play()
publish()
let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in publish() }
app.run()
