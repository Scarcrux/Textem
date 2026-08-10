// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "scarcrux-textem",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(name: "scarcrux-textem"),
        .testTarget(name: "TextemTests", dependencies: ["scarcrux-textem"]),
    ]
)
