// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StayAwake",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Auto-update checking ("Check for Updates..."), reading appcast.xml from GitHub.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "StayAwake",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/StayAwake",
            linkerSettings: [
                // SPM links against Sparkle.framework but, unlike an Xcode build phase,
                // never copies it into the app bundle or points the binary at it there --
                // build.sh does the copying into Contents/Frameworks, and this rpath entry
                // is what lets the built executable actually find it at that location once
                // installed, instead of only working from inside .build/.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
