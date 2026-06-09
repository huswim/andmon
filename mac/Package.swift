// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AndmonHost",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "AndmonHost", targets: ["AndmonHost"]),
    ],
    targets: [
        .target(
            name: "VirtualDisplayBridge",
            path: "Sources/VirtualDisplayBridge",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "AndmonHost",
            dependencies: ["VirtualDisplayBridge"],
            path: "Sources/AndmonHost",
            swiftSettings: [.unsafeFlags(["-strict-concurrency=minimal"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "AndmonHostTests",
            dependencies: ["AndmonHost"],
            path: "Tests/AndmonHostTests"
        ),
    ]
)
