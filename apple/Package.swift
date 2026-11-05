// swift-tools-version:5.10
import PackageDescription

// DiskIndexerKit holds everything shared between the macOS app and the
// planned iPhone/iPad app: API client, models, view model and SwiftUI views.
// Anything that needs Process or AppKit lives in DiskIndexerMac.
// DiskIndexerSSH is the in-process SSH transport (Citadel) the iPhone/iPad
// app uses, since iOS has no ssh binary; it builds for macOS too, for tests.
let package = Package(
    name: "DiskIndexer",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DiskIndexerKit", targets: ["DiskIndexerKit"]),
        .library(name: "DiskIndexerSSH", targets: ["DiskIndexerSSH"]),
        .executable(name: "DiskIndexerMac", targets: ["DiskIndexerMac"]),
        .executable(name: "DiskIndexerIOS", targets: ["DiskIndexerIOS"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", .upToNextMinor(from: "0.12.1")),
    ],
    targets: [
        .target(name: "DiskIndexerKit"),
        .target(name: "DiskIndexerSSH", dependencies: [
            "DiskIndexerKit",
            .product(name: "Citadel", package: "Citadel"),
        ]),
        .executableTarget(name: "DiskIndexerMac", dependencies: ["DiskIndexerKit"]),
        // iPhone/iPad app (spike). Built for the Simulator by scripts/ios-sim-app.sh.
        .executableTarget(name: "DiskIndexerIOS", dependencies: ["DiskIndexerKit", "DiskIndexerSSH"]),
        .testTarget(name: "DiskIndexerKitTests", dependencies: ["DiskIndexerKit"]),
        .testTarget(name: "DiskIndexerSSHTests", dependencies: ["DiskIndexerSSH"]),
    ]
)
