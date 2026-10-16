// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "crypto",
    products: [.library(name: "Shared", targets: ["Shared"])],
    dependencies: [.package(url: "https://github.com/apple/swift-crypto", from: "3.0.0")],
    targets: [.target(name: "Shared", dependencies: [.product(name: "Crypto", package: "swift-crypto")])]
)
