// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    dependencies: [
        // On-device NVIDIA Parakeet speech-to-text (CoreML, Apache-2.0).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "Perch",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Perch"
        )
    ]
)
