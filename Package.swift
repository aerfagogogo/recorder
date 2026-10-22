// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "qishui-audio-capture",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "qishui-capture", targets: ["QishuiCapture"]),
        .executable(name: "qishui-capture-ui", targets: ["QishuiCaptureGUI"])
    ],
    targets: [
        .executableTarget(
            name: "QishuiCapture",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(name: "QishuiCaptureGUI", swiftSettings: [.unsafeFlags(["-parse-as-library"])])
    ]
)
