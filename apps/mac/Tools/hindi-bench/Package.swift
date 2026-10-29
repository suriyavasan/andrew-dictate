// swift-tools-version: 6.2
import PackageDescription

// a developer tool, not part of the app. it streams Hindi audio through the
// candidate live engines (Apple DictationTranscriber, NVIDIA Nemotron 3.5 via
// FluidAudio, WhisperKit large-v3) and measures latency, accuracy and language
// stability. see README.md and REPORT.md.
let package = Package(
    name: "hindi-bench",
    platforms: [
        .macOS("26.0"),
    ],
    dependencies: [
        // FluidAudio is newer than the app's pin (0.15.5): the Nemotron 3.5
        // multilingual streaming manager first ships in 0.18.0. this is a
        // separate package, so the app is untouched.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.18.0"),
        // the same as apps/mac/project.yml.
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "hindi-bench",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
    ]
)
