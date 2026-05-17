// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BuildBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "BuildBar",
            path: "Sources/BuildBar"
        )
    ]
)
