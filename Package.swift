// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EpokRum",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "EpokRum", targets: ["EpokRum"]),
        .library(name: "EpokReplay", targets: ["EpokReplay"])
    ],
    dependencies: [
        .package(url: "https://github.com/PostHog/posthog-ios.git", exact: "3.92.0")
    ],
    targets: [
        .target(name: "EpokRum"),
        .target(name: "EpokReplay", dependencies: [
            "EpokRum", .product(name: "PostHog", package: "posthog-ios")
        ], resources: [.copy("PostHog-LICENSE.txt")]),
        .testTarget(name: "EpokRumTests", dependencies: ["EpokRum"]),
        .testTarget(name: "EpokReplayTests", dependencies: ["EpokReplay"])
    ],
    swiftLanguageModes: [.v6]
)
