// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "resources",
    targets: [.target(name: "WithResources", resources: [.copy("data.txt")])]
)
