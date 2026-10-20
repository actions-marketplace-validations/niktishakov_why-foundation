// swift-tools-version: 6.0
import PackageDescription

// This package and Dep both declare a target named Shared, so SwiftPM can't load the graph.
let package = Package(
    name: "conflict",
    dependencies: [.package(path: "Dep")],
    targets: [.target(name: "Shared", dependencies: [.product(name: "Dep", package: "Dep")])]
)
