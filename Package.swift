// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "clisland",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "clisland", targets: ["clisland"]),
    ],
    targets: [
        .target(name: "CLIslandCore"),
        .executableTarget(
            name: "clisland",
            dependencies: ["CLIslandCore"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]
        ),
        .testTarget(name: "CLIslandCoreTests", dependencies: ["CLIslandCore"]),
    ]
)
