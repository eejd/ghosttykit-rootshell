// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ghosttykit-rootshell",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .visionOS(.v1)],
    products: [
        .library(name: "GhosttyKitAppStore", targets: ["GhosttyKitAppStore"]),
        .library(name: "GhosttyKitStandalone", targets: ["GhosttyKitStandalone"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKitAppStore",
            url: "https://github.com/eejd/ghosttykit-rootshell/releases/download/v0.2.6/GhosttyKitAppStore.xcframework.zip",
            checksum: "23df4e104f9d76d3b114ff800a1f1eca4a3d0008aee9d3bcfe8159090f28bc9e"
        ),
        .binaryTarget(
            name: "GhosttyKitStandalone",
            url: "https://github.com/eejd/ghosttykit-rootshell/releases/download/v0.2.6/GhosttyKitStandalone.xcframework.zip",
            checksum: "e494e255b5a4f4af5c47748a5c6df7ae0da79af811ec6788f5a6a9d0b03d5cde"
        ),
    ]
)
