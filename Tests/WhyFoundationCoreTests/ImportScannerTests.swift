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

/// APIs that kept real packages from building with FoundationEssentials from Swift 6.4.1.
@Suite struct MissingAPITests {
    let configuration = PlatformBuildConfiguration(platform: .android, graphModules: [])

    func apis(_ source: String) -> [FullFoundationAPI: Set<String>] {
        ImportScanner.scan(source, configuration: configuration).fullFoundationAPIs
    }

    @Test func stringMembers() {
        // From Splash, Files, SwiftyBeaver, hummingbird and swifter.
        let source = """
        import Foundation
        extension String {
            func removing(_ text: String) -> String { replacingOccurrences(of: text, with: "") }
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let parent = path.range(of: "../")
        let padded = "".padding(toLength: 2, withPad: " ", startingAt: 0)
        let same = field.name.caseInsensitiveCompare(host) == .orderedSame
        let name = tokens.first?.removingPercentEncoding
        let joined = path.appending("/")
        """
        #expect(apis(source) == [.corelibsOnly: [
            "replacingOccurrences", "trimmingCharacters", "range(of:)", "padding(toLength:)",
            "caseInsensitiveCompare", "removingPercentEncoding", "appending(_:)",
        ]])
    }

    @Test func stringInitializers() {
        let source = """
        import Foundation
        let hex = String(format: "%02x", byte)
        let text = try String(contentsOf: file)
        let json = try String(contentsOfFile: path)
        let name = String(utf8String: pointer)
        let fine = try String(contentsOf: file, encoding: .utf8)
        let plain = String(42)
        """
        #expect(apis(source) == [.corelibsOnly: ["String(format:)", "String(contentsOf:)", "String(utf8String:)"]])
    }

    @Test func essentialsAPIsWithTheSameNames() {
        let source = """
        import FoundationEssentials
        let range = 0..<3
        print(range.count)
        let days = calendar.range(of: .day, in: .month, for: date)
        let file = url.appending(path: "x").appending(component: "y")
        var padding = 4
        padding += 1
        let found = data.firstRange(of: needle)
        """
        #expect(apis(source).isEmpty)
    }

    @Test func objectiveCAndCoreFoundationNames() {
        // From Repeat, Factory, swift-openapi-generator and Alamofire.
        let source = """
        import Foundation
        let id = NSUUID().uuidString
        final class Lock: NSLocking {}
        let missing = NSNotFound
        let now = CFAbsoluteTimeGetCurrent()
        var isDirectory: ObjCBool = false
        let allowed = CharacterSet.urlQueryAllowed
        """
        #expect(apis(source) == [.corelibsOnly: [
            "NSUUID", "NSLocking", "NSNotFound", "CFAbsoluteTimeGetCurrent", "ObjCBool", "CharacterSet",
        ]])
    }

    @Test func networkingTypes() {
        let source = """
        import Foundation
        final class Delegate: NSObject, URLSessionTaskDelegate {}
        func retry(_ error: URLError) {}
        """
        #expect(apis(source) == [.networking: ["URLSessionTaskDelegate", "URLError"], .corelibsOnly: ["NSObject"]])
    }
}
