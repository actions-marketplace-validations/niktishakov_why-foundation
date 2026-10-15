// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "why-foundation",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "why-foundation", targets: ["why-foundation"]),
        .library(name: "WhyFoundationCore", targets: ["WhyFoundationCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "602.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "why-foundation",
            dependencies: [
                "WhyFoundationCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "WhyFoundationCore",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftIfConfig", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "WhyFoundationCoreTests",
            dependencies: ["WhyFoundationCore"]
        ),
    ]
)
