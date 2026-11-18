// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "InferoidNotes",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "InferoidNotesKit", targets: ["InferoidNotesKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2"),
    ],
    targets: [
        .target(
            name: "InferoidNotesKit",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/InferoidNotesKit"
        ),
        .executableTarget(
            name: "InferoidNotes",
            dependencies: ["InferoidNotesKit"],
            path: "Sources/InferoidNotes"
        ),
        .testTarget(
            name: "InferoidNotesTests",
            dependencies: ["InferoidNotesKit"],
            path: "Tests/InferoidNotesTests"
        ),
    ]
)
