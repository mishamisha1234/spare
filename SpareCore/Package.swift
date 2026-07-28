// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SpareCore",
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
