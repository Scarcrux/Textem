// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "scarcrux-textem",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .executableTarget(name: "scarcrux-textem", dependencies: ["NativeAutoFillCore", .product(name: "Sparkle", package: "Sparkle")]),
        .target(name: "NativeAutoFillCore", path: "Experiments/NativeAutoFill/Core"),
        .target(name: "NativeAutoFillProvider", dependencies: ["NativeAutoFillCore"],
                path: "Experiments/NativeAutoFill/Provider"),
        .testTarget(name: "TextemTests", dependencies: ["scarcrux-textem", "NativeAutoFillProvider"]),
    ]
)
