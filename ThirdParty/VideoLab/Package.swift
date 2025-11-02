// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VideoLab",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "VideoLab",
            targets: ["VideoLab"]
        )
    ],
    targets: [
        .target(
            name: "VideoLab",
            path: ".",
            resources: [
                .process("VideoLab.bundle")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
