// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StayAwake",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "StayAwake",
            path: "Sources/StayAwake"
        )
    ]
)
