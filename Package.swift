// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SiloSwift",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
    ],
    products: [
        .library(name: "SiloSwift", targets: ["SiloSwift"]),
    ],
    targets: [
        .target(name: "SiloSwift"),
        .testTarget(name: "SiloSwiftTests", dependencies: ["SiloSwift"]),
    ]
)
