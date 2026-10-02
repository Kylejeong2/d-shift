// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DShift",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DShift", path: "Sources/DShift"),
        .testTarget(name: "DShiftTests", dependencies: ["DShift"], path: "Tests/DShiftTests"),
    ]
)
