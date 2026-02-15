// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StoreCheckCore",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "StoreCheckCore", targets: ["StoreCheckCore"])
    ],
    targets: [
        .target(name: "StoreCheckCore", path: "Sources"),
        .testTarget(name: "StoreCheckCoreTests", dependencies: ["StoreCheckCore"], path: "Tests")
    ]
)
