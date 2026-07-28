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
    ],
    targets: [
        // Platform-agnostic. Must contain no SwiftUI, SwiftData, StoreKit,
        // UIKit, or WidgetKit imports so it builds and tests on Linux and
        // Windows. CI enforces this with a grep check.
        .target(name: "SpareCore"),
        .testTarget(name: "SpareCoreTests", dependencies: ["SpareCore"]),
    ]
)
