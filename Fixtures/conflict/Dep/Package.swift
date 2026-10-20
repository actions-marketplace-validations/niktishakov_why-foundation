// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dep",
    products: [.library(name: "Dep", targets: ["Shared"])],
    targets: [.target(name: "Shared")]
)
