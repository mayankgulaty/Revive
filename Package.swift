// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Revive",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "revive",
            path: "Sources/revive",
            resources: [.copy("web")],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
    ]
)
