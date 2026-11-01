// swift-tools-version:5.10
import PackageDescription

// DiskIndexerKit holds everything shared between the macOS app and the
// planned iPhone/iPad app: API client, models, view model and SwiftUI views.
// Anything that needs Process or AppKit lives in DiskIndexerMac.
let package = Package(
    name: "DiskIndexer",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DiskIndexerKit", targets: ["DiskIndexerKit"]),
        .executable(name: "DiskIndexerMac", targets: ["DiskIndexerMac"]),
    ],
    targets: [
        .target(name: "DiskIndexerKit"),
        .executableTarget(name: "DiskIndexerMac", dependencies: ["DiskIndexerKit"]),
        .testTarget(name: "DiskIndexerKitTests", dependencies: ["DiskIndexerKit"]),
    ]
)
