// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VStreamKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AddonKit", targets: ["AddonKit"]),
        .library(name: "StremioAPI", targets: ["StremioAPI"]),
        .library(name: "TraktKit", targets: ["TraktKit"]),
        .library(name: "DebridKit", targets: ["DebridKit"]),
        .library(name: "TorrentKit", targets: ["TorrentKit"]),
        .library(name: "PlayerKit", targets: ["PlayerKit"]),
        .library(name: "VStreamCore", targets: ["VStreamCore"]),
    ],
    dependencies: [
        .package(path: "../../MPVKit"),
        .package(path: "../../nuvio-engine/platform/apple"),
    ],
    targets: [
        .target(name: "AddonKit"),
        .target(name: "StremioAPI", dependencies: ["AddonKit"]),
        .target(name: "TraktKit"),
        .target(name: "DebridKit"),
        .target(
            name: "TorrentKit",
            dependencies: [.product(name: "NuvioEngine", package: "apple")]
        ),
        .target(
            name: "PlayerKit",
            dependencies: [.product(name: "MPVKit", package: "MPVKit")]
        ),
        .target(
            name: "VStreamCore",
            dependencies: ["AddonKit", "StremioAPI", "TraktKit", "DebridKit", "TorrentKit", "PlayerKit"]
        ),
        .testTarget(
            name: "AddonKitTests",
            dependencies: ["AddonKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "TraktKitTests",
            dependencies: ["TraktKit"]
        ),
        .testTarget(
            name: "VStreamCoreTests",
            dependencies: ["VStreamCore", "DebridKit", "AddonKit", "StremioAPI"]
        ),
    ]
)
