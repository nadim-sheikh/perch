// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OpenBuddy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenBuddy",
            path: "Sources/OpenBuddy"
        )
    ]
)
