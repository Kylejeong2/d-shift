// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DShift",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DShift", path: "Sources/DShift",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker",
                    "Packaging/EmbeddedInfo.plist",
                ])
            ]),
        .testTarget(name: "DShiftTests", dependencies: ["DShift"], path: "Tests/DShiftTests"),
    ]
)
