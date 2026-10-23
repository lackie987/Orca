// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Orca",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Orca",
            path: "Sources/Orca"
        )
    ]
)
