// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "WhoRuns",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "WhoRuns",
            path: "Sources/WhoRuns"
        )
    ]
)
