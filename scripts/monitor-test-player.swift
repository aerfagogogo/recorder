import AppKit
import AVFoundation

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let tone = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
tone.numberOfLoops = -1
tone.play()
app.run()
