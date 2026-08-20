// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SpareCore",
    // Required for the iOS build: without it SwiftPM assumes the oldest
    // supported deployment target, where async/await and AsyncThrowingStream
    // do not exist. Ignored on Linux and Windows, which have no platform
    // version gating.
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SpareCore", targets: ["SpareCore"]),
        // Not a dependency of the app: the iOS target depends on the library
        // product only, so this never reaches a device build.
        .executable(name: "spare-batch", targets: ["SpareBatch"]),
    ],
    targets: [
        // Platform-agnostic. Must contain no SwiftUI, SwiftData, StoreKit,
        // UIKit, or WidgetKit imports so it builds and tests on Linux and
        // Windows. CI enforces this with a grep check.
        .target(name: "SpareCore"),
        .testTarget(name: "SpareCoreTests", dependencies: ["SpareCore"]),
        // Offline tool: generates a batch of lessons through the real pipeline
        // and the real prompts, for reading and judging. Deliberately in this
        // package rather than a script elsewhere, so it uses `Prompts.swift`
        // itself and cannot drift from what the app sends. Same platform rules
        // as SpareCore — CI greps it for Apple-only imports too.
        .executableTarget(name: "SpareBatch", dependencies: ["SpareCore"]),
    ]
)
