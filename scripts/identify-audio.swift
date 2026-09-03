import AVFoundation
import Foundation
import ShazamKit

@main
struct IdentifyAudio {
    static func main() async {
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            do {
                let signature = try await SHSignatureGenerator.signature(from: AVURLAsset(url: url))
                let result = await SHSession().result(from: signature)
                switch result {
                case .match(let match):
                    if let item = match.mediaItems.first {
                        print("\(url.lastPathComponent)\tMATCH\t\(item.title ?? "")\t\(item.artist ?? "")")
                    } else {
                        print("\(url.lastPathComponent)\tNO_ITEMS")
                    }
                case .noMatch:
                    print("\(url.lastPathComponent)\tNO_MATCH")
                case .error(let error, _):
                    print("\(url.lastPathComponent)\tERROR\t\(error.localizedDescription)")
                @unknown default:
                    print("\(url.lastPathComponent)\tUNKNOWN")
                }
            } catch {
                print("\(url.lastPathComponent)\tSIGNATURE_ERROR\t\(error.localizedDescription)")
            }
        }
    }
}
