// swift-tools-version:5.9
import PackageDescription

// Platform-independent core of the Norwegian 4x4 app: workout state machine,
// timing, heart-rate parsing and zones, statistics, persistence and music
// orchestration. Depends on Foundation only, so `swift test` runs on macOS
// without a simulator (and on Linux/Windows toolchains).
let package = Package(
    name: "FourByFourCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FourByFourCore", targets: ["FourByFourCore"])
    ],
    targets: [
        .target(name: "FourByFourCore"),
        .testTarget(name: "FourByFourCoreTests", dependencies: ["FourByFourCore"])
    ]
)
