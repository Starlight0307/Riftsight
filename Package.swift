// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Riftsight",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Riftsight"),
    ]
)
