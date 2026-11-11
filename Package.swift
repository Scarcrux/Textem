// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "scarcrux-textem",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(name: "scarcrux-textem", dependencies: ["NativeAutoFillCore"]),
        .target(name: "NativeAutoFillCore", path: "Experiments/NativeAutoFill/Core"),
        .target(name: "NativeAutoFillProvider", dependencies: ["NativeAutoFillCore"],
                path: "Experiments/NativeAutoFill/Provider"),
        .testTarget(name: "TextemTests", dependencies: ["scarcrux-textem", "NativeAutoFillProvider"]),
    ]
)
