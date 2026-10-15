import Testing
@testable import WhyFoundationCore

@Suite struct ImportScannerTests {
    func imports(_ source: String, on platform: TargetPlatform = .android) -> [HeavyImport] {
        let configuration = PlatformBuildConfiguration(platform: platform, graphModules: [])
        return ImportScanner.heavyImports(in: source, configuration: configuration)
    }

    @Test func plainImport() {
        let found = imports("import Foundation\nlet x = 1\n")
        #expect(found == [HeavyImport(module: .foundation, line: 1, isExported: false)])
    }

    @Test func essentialsIsFine() {
        #expect(imports("import FoundationEssentials\n").isEmpty)
    }

    @Test func canImportEssentialsFallback() {
        let source = """
        #if canImport(FoundationEssentials)
        import FoundationEssentials
        #else
        import Foundation
        #endif
        """
        #expect(imports(source).isEmpty)
    }

    @Test func darwinOnlyImport() {
        let source = """
        #if canImport(Darwin)
        import Foundation
        #endif
        """
        #expect(imports(source).isEmpty)
    }

    @Test func linuxConditionDoesNotCoverAndroid() {
        let source = """
        #if os(Linux)
        import FoundationEssentials
        #else
        import Foundation
        #endif
        """
        #expect(imports(source, on: .android).map(\.module) == [.foundation])
        #expect(imports(source, on: .linux).isEmpty)
    }

    @Test func otherHeavyModules() {
        let source = """
        @preconcurrency import FoundationNetworking
        import struct FoundationXML.XMLParser
        @_exported import Foundation
        """
        let found = imports(source)
        #expect(found.map(\.module) == [.foundationNetworking, .foundationXML, .foundation])
        #expect(found.map(\.isExported) == [false, false, true])
        #expect(found.map(\.line) == [1, 2, 3])
    }

    @Test func nestedConditions() {
        let source = """
        #if os(Android)
          #if canImport(FoundationEssentials)
          import FoundationEssentials
          #endif
        #elseif canImport(Darwin)
        import Foundation
        #else
        import Foundation
        #endif
        """
        #expect(imports(source, on: .android).isEmpty)
        #expect(imports(source, on: .linux).map(\.module) == [.foundation])
    }
}

@Suite struct TraitConditionTests {
    @Test func enabledTraitActivatesImport() {
        let source = """
        #if FoundationNetworking
        import FoundationNetworking
        #endif
        """
        let on = PlatformBuildConfiguration(platform: .android, graphModules: [], customConditions: ["FoundationNetworking"])
        let off = PlatformBuildConfiguration(platform: .android, graphModules: [])
        #expect(ImportScanner.heavyImports(in: source, configuration: on).map(\.module) == [.foundationNetworking])
        #expect(ImportScanner.heavyImports(in: source, configuration: off).isEmpty)
    }
}

@Suite struct FileScanTests {
    let configuration = PlatformBuildConfiguration(platform: .android, graphModules: [])

    @Test func appleOnlyImportsRespectConditions() {
        let source = """
        #if canImport(UIKit)
        import UIKit
        #endif
        import SwiftUI
        """
        #expect(ImportScanner.scan(source, configuration: configuration).appleOnlyImports == ["SwiftUI"])
    }

    @Test func fullFoundationAPIs() {
        let source = """
        import Foundation
        let session = URLSession.shared
        #if canImport(Darwin)
        let formatter = DateFormatter()
        #endif
        let data = try JSONSerialization.data(withJSONObject: [:])
        """
        let apis = ImportScanner.scan(source, configuration: configuration).fullFoundationAPIs
        #expect(apis == [.networking: ["URLSession"], .corelibsOnly: ["JSONSerialization"]])
    }

    @Test func typesMissingFromEssentials() {
        let source = """
        import Foundation
        func move(fromOffsets source: IndexSet, toOffset destination: Int) {}
        let distance = Measurement(value: 1, unit: UnitLength.meters)
        func describe(_ error: any Error) -> String { error.localizedDescription }
        """
        let apis = ImportScanner.scan(source, configuration: configuration).fullFoundationAPIs
        #expect(apis == [.corelibsOnly: ["IndexSet", "localizedDescription"], .formatting: ["Measurement", "UnitLength"]])
    }
}
