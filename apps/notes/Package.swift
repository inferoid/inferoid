// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "InferoidNotes",
    platforms: [.macOS("14.4")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2"),
    ],
    targets: [
        .executableTarget(
            name: "InferoidNotes",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/InferoidNotes"
        ),
    ]
)
