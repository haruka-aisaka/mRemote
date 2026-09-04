// swift-tools-version: 6.0
import PackageDescription

// The product app is an Xcode project; this package holds the layers that do
// not need UIKit, so they can be built and tested on the development host
// without a Simulator. The module boundaries follow docs/architecture.md,
// section 3: dependencies point downwards only, and nothing here may import a
// protocol implementation.
let package = Package(
    name: "mRemoteKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SessionCore", targets: ["SessionCore"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "AppleAdapters", targets: ["AppleAdapters"]),
    ],
    targets: [
        .target(name: "SessionCore"),
        .target(name: "Persistence", dependencies: ["SessionCore"]),
        .target(
            name: "AppleAdapters",
            dependencies: ["SessionCore"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(name: "SessionCoreTests", dependencies: ["SessionCore"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
        .testTarget(name: "AppleAdaptersTests", dependencies: ["AppleAdapters"]),
    ]
)
