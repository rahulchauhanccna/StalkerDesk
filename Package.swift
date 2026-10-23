// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StalkerDesk",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "StalkerDesk", targets: ["StalkerDesk"]),
        .library(name: "StalkerDeskCore", targets: ["StalkerDeskCore"]),
        .executable(name: "StalkerDeskChecks", targets: ["StalkerDeskChecks"])
    ],
    targets: [
        .target(
            name: "StalkerDeskCore",
            path: "Sources/StalkerDeskCore"
        ),
        .executableTarget(
            name: "StalkerDesk",
            dependencies: ["StalkerDeskCore"],
            path: "Sources/StalkerDesk"
        ),
        .executableTarget(
            name: "StalkerDeskChecks",
            dependencies: ["StalkerDeskCore"],
            path: "Sources/StalkerDeskChecks"
        )
    ]
)
