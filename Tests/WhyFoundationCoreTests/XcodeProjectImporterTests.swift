import Foundation
import Testing
@testable import WhyFoundationCore

@Suite struct XcodeProjectImporterTests {
    let objects: [String: [String: Any]] = [
        "R1": ["isa": "XCRemoteSwiftPackageReference", "repositoryURL": "https://github.com/apple/swift-log.git",
               "requirement": ["kind": "upToNextMajorVersion", "minimumVersion": "2.0.0"]],
        "L1": ["isa": "XCLocalSwiftPackageReference", "relativePath": "Modules/DesignSystem"],
        "P1": ["isa": "XCSwiftPackageProductDependency", "package": "R1", "productName": "Logging"],
        "P2": ["isa": "XCSwiftPackageProductDependency", "productName": "DesignSystem"],
        "T1": ["isa": "PBXNativeTarget", "name": "My App", "productType": "com.apple.product-type.application",
               "packageProductDependencies": ["P1", "P2"]],
        "T2": ["isa": "PBXNativeTarget", "name": "MyAppTests", "productType": "com.apple.product-type.bundle.unit-test",
               "packageProductDependencies": []],
    ]

    func parse() -> XcodeProjectImporter.Project {
        XcodeProjectImporter.parse(
            objects: objects,
            projectDirectory: URL(fileURLWithPath: "/work/app"),
            localProducts: { _ in ("designsystem", ["DesignSystem"]) }
        )
    }

    @Test func readsTargetsAndProducts() {
        let project = parse()
        #expect(project.targets.map(\.name) == ["My App", "MyAppTests"])
        #expect(project.targets[0].products.map(\.name) == ["Logging", "DesignSystem"])
        #expect(project.targets[0].products.map(\.package) == ["swift-log", "designsystem"])
        #expect(project.targets[1].isTest)
        #expect(project.localPackages.map(\.path) == ["/work/app/Modules/DesignSystem"])
    }

    @Test func writesManifest() {
        let project = parse()
        let manifest = XcodeProjectImporter.manifest(project: project, targets: [project.targets[0]])
        #expect(manifest.contains(#".package(url: "https://github.com/apple/swift-log.git", from: "2.0.0"),"#))
        #expect(manifest.contains(#".package(path: "/work/app/Modules/DesignSystem"),"#))
        #expect(manifest.contains(#".target(name: "My_App", dependencies: [.product(name: "Logging", package: "swift-log"), .product(name: "DesignSystem", package: "designsystem")]),"#))
    }

    @Test func requirements() {
        #expect(XcodeProjectImporter.requirement(["kind": "upToNextMinorVersion", "minimumVersion": "1.2.0"]) == #".upToNextMinor(from: "1.2.0")"#)
        #expect(XcodeProjectImporter.requirement(["kind": "exactVersion", "version": "1.0.0"]) == #"exact: "1.0.0""#)
        #expect(XcodeProjectImporter.requirement(["kind": "versionRange", "minimumVersion": "1.0.0", "maximumVersion": "2.0.0"]) == #""1.0.0"..<"2.0.0""#)
        #expect(XcodeProjectImporter.requirement(["kind": "branch", "branch": "dev"]) == #"branch: "dev""#)
    }
}
