// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WhisperDictationHotkey",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "WhisperDictationCore", targets: ["WhisperDictationCore"]),
    ],
    targets: [
        .target(
            name: "WhisperDictationCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
            ]
        ),
        .executableTarget(
            name: "whisper-dictation-daemon",
            dependencies: ["WhisperDictationCore"]
        ),
        .executableTarget(
            name: "whisper-dictation-ctl",
            dependencies: ["WhisperDictationCore"]
        ),
    ]
)
