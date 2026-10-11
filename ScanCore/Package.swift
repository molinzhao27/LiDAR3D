// swift-tools-version:5.9
import PackageDescription

// Platform-independent scanning core: geometry, depth fusion and file formats.
// Uses only the Swift standard library and Foundation so it builds and tests
// on macOS and Linux as well as iOS.
let package = Package(
    name: "ScanCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ScanCore", targets: ["ScanCore"]),
    ],
    targets: [
        .target(name: "ScanCore"),
        .testTarget(name: "ScanCoreTests", dependencies: ["ScanCore"]),
    ]
)
