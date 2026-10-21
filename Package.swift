// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AISubsUsage-MenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CCrypto",
            path: "Sources/CCrypto",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "AISubsUsageMenuBar",
            dependencies: ["CCrypto"],
            path: "Sources/AISubsUsageMenuBar"
        ),
        .testTarget(
            name: "AISubsUsageMenuBarTests",
            dependencies: ["AISubsUsageMenuBar"],
            path: "Tests/AISubsUsageMenuBarTests"
        ),
    ]
)
