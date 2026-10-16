// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "log",
    products: [.library(name: "Shared", targets: ["Shared"])],
    dependencies: [.package(url: "https://github.com/apple/swift-log", from: "1.6.0")],
    targets: [.target(name: "Shared", dependencies: [.product(name: "Logging", package: "swift-log")])]
)
