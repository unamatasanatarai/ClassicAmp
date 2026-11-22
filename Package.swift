// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "ClassicAmp",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(
            name: "ClassicAmp",
            targets: ["ClassicAmp"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "ClassicAmp",
            dependencies: [],
            path: "Sources/App"
        ),
        .testTarget(
            name: "AppTests",
            dependencies: ["ClassicAmp"],
            path: "Tests/AppTests"
        )
    ]
)
