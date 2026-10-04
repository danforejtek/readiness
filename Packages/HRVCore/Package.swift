// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HRVCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HRVCore", targets: ["HRVCore"]),
    ],
    targets: [
        .target(name: "HRVCore"),
        .testTarget(
            name: "HRVCoreTests",
            dependencies: ["HRVCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
