// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "GraphCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GraphCore", targets: ["GraphCore"])
    ],
    targets: [
        .target(name: "GraphCore"),
        .testTarget(name: "GraphCoreTests", dependencies: ["GraphCore"]),
    ]
)
