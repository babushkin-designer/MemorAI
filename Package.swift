// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MemorAI",
    platforms: [.macOS(.v14)],
    targets: [
        // Lets Swift survive the ObjC exceptions AVFAudio raises on device
        // transitions; without it they abort the process.
        .target(
            name: "ObjCTry",
            path: "ObjCTry"
        ),
        .executableTarget(
            name: "MemorAI",
            dependencies: ["ObjCTry"],
            path: "AutoRec",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Vision"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .testTarget(
            name: "MemorAITests",
            dependencies: ["MemorAI", "ObjCTry"],
            path: "Tests/MemorAITests"
        ),
    ]
)
// Run tests: swift test
