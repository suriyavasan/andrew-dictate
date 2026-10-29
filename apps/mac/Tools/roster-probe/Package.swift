// swift-tools-version: 6.2
import PackageDescription

// a developer tool, not part of the app. it reads what Zoom and Google Meet
// (in Chrome, Arc, Safari) expose through the macOS Accessibility API during a
// real call: who is in it, and who is speaking right now. no dependencies.
let package = Package(
    name: "roster-probe",
    platforms: [
        .macOS("14.0"),
    ],
    targets: [
        .executableTarget(
            name: "roster-probe",
            swiftSettings: [
                // a command line tool with a few globals (the stop flag); strict
                // concurrency checking buys nothing here.
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
