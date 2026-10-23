import Foundation
import Testing
@testable import WhyFoundationCore

@Suite struct DependencyParsingTests {
    func parse(_ json: String) throws -> Dependency? {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return GraphLoader.parseDependency(object)
    }

    @Test func productWithPlatformCondition() throws {
        let dependency = try parse(#"{"product": ["OrderedCollections", "swift-collections", null, {"platformNames": ["linux"]}]}"#)
        guard case .product(let name, let package, let condition) = dependency else {
            Issue.record("expected a product dependency")
            return
        }
        #expect(name == "OrderedCollections")
        #expect(package == "swift-collections")
        #expect(condition.platforms == ["linux"])
    }

    @Test func byNameWithoutCondition() throws {
        let dependency = try parse(#"{"byName": ["CoreMetrics", null]}"#)
        guard case .byName(let name, let condition) = dependency else {
            Issue.record("expected a by-name dependency")
            return
        }
        #expect(name == "CoreMetrics")
        #expect(condition == DependencyCondition(platforms: nil, traits: nil))
    }

    @Test func traitCondition() throws {
        let dependency = try parse(#"{"product": ["CombineSchedulers", "combine-schedulers", null, {"traits": ["CombineSchedulers"]}]}"#)
        #expect(dependency?.condition.traits == ["CombineSchedulers"])
    }

    @Test func libraryProductsAndResourcePaths() {
        let manifest: [String: Any] = [
            "name": "swift-nio-ssl",
            "products": [
                ["name": "NIOSSL", "targets": ["NIOSSL"], "type": ["library": ["automatic"]]],
                ["name": "NIOTLSServer", "targets": ["NIOTLSServer"], "type": ["executable": NSNull()]],
            ],
            "targets": [
                ["name": "NIOSSL", "type": "regular", "resources": [["path": "PrivacyInfo.xcprivacy", "rule": ["copy": [:]]]]],
                ["name": "NIOTLSServer", "type": "executable"],
            ],
        ]
        let package = GraphLoader.makePackage(identity: "swift-nio-ssl", path: URL(fileURLWithPath: "/"), manifest: manifest, requestedTraits: [])
        #expect(package.libraryProducts == ["NIOSSL"])
        #expect(package.targets["NIOSSL"]?.resourcePaths == ["PrivacyInfo.xcprivacy"])
        #expect(package.targets["NIOSSL"]?.hasOnlyPrivacyManifests == true)
        #expect(package.targets["NIOTLSServer"]?.hasDeclaredResources == false)
    }

    @Test func defaultTraitExpandsTransitively() {
        let manifest: [String: Any] = ["traits": [
            ["name": "default", "enabledTraits": ["Foundation"]],
            ["name": "Foundation", "enabledTraits": ["FoundationNetworking"]],
            ["name": "FoundationNetworking", "enabledTraits": []],
            ["name": "Unused", "enabledTraits": []],
        ]]
        #expect(GraphLoader.expandTraits(["default"], manifest: manifest) == ["default", "Foundation", "FoundationNetworking"])
    }
}

@Suite struct SwiftDefineTests {
    func target(_ settings: [[String: Any]]) -> TargetNode {
        TargetNode(
            name: "Crypto", kind: .regular, customPath: nil, sources: nil, exclude: [],
            hasDeclaredResources: false, dependencies: [],
            swiftDefines: settings.compactMap(GraphLoader.parseSwiftDefine)
        )
    }

    @Test func platformLimitedDefine() {
        let crypto = target([
            ["tool": "swift", "kind": ["define": ["_0": "CRYPTO_IN_SWIFTPM"]]],
            ["tool": "swift", "kind": ["define": ["_0": "CRYPTO_IN_SWIFTPM_FORCE_BUILD_API"]],
             "condition": ["platformNames": ["linux", "android"]]],
            ["tool": "swift", "kind": ["define": ["_0": "DEBUG_ONLY"]], "condition": ["config": "debug"]],
            ["tool": "c", "kind": ["define": ["_0": "C_ONLY"]]],
        ])
        #expect(crypto.activeDefines(for: .android) == ["CRYPTO_IN_SWIFTPM", "CRYPTO_IN_SWIFTPM_FORCE_BUILD_API"])
    }
}
