import SwiftIfConfig
import SwiftSyntax

/// The platform whose build is being analyzed. Decides how `#if` blocks are evaluated.
public enum TargetPlatform: String, CaseIterable, Sendable {
    case android
    case linux

    /// The name SwiftPM uses for this platform in `.when(platforms:)` conditions.
    var packageManifestName: String { rawValue }

    /// Modules the platform SDK provides, besides the modules of the package graph.
    var sdkModules: Set<String> {
        var modules: Set<String> = [
            "Swift", "_Concurrency", "_StringProcessing", "RegexBuilder", "Synchronization",
            "Observation", "Distributed", "Dispatch", "XCTest", "Testing",
            "Foundation", "FoundationEssentials", "FoundationInternationalization",
            "FoundationNetworking", "FoundationXML", "CoreFoundation",
        ]
        switch self {
        case .android: modules.formUnion(["Android", "Bionic"])
        case .linux: modules.formUnion(["Glibc"])
        }
        return modules
    }
}

/// A `BuildConfiguration` that answers `#if` queries the way the compiler would
/// for a release build targeting `platform`.
struct PlatformBuildConfiguration: BuildConfiguration {
    let platform: TargetPlatform
    /// Every module that `canImport` should report as available.
    let importableModules: Set<String>
    /// Conditions set for the package being scanned: its enabled traits.
    let customConditions: Set<String>

    init(platform: TargetPlatform, graphModules: Set<String>, customConditions: Set<String> = []) {
        self.platform = platform
        self.importableModules = platform.sdkModules.union(graphModules)
        self.customConditions = customConditions
    }

    func isCustomConditionSet(name: String) throws -> Bool { customConditions.contains(name) }
    func hasFeature(name: String) throws -> Bool { false }
    func hasAttribute(name: String) throws -> Bool { false }

    func canImport(importPath: [(TokenSyntax, String)], version: CanImportVersion) throws -> Bool {
        guard let module = importPath.first?.1 else { return false }
        return importableModules.contains(module)
    }

    func isActiveTargetOS(name: String) throws -> Bool {
        switch platform {
        case .android: name == "Android"
        case .linux: name == "Linux"
        }
    }

    func isActiveTargetArchitecture(name: String) throws -> Bool { name == "arm64" }
    func isActiveTargetEnvironment(name: String) throws -> Bool { false }
    func isActiveTargetRuntime(name: String) throws -> Bool { name == "_Native" }
    func isActiveTargetPointerAuthentication(name: String) throws -> Bool { false }
    func isActiveTargetObjectFileFormat(name: String) throws -> Bool { name == "ELF" }

    var targetPointerBitWidth: Int { 64 }
    var targetAtomicBitWidths: [Int] { [32, 64, 128] }
    var endianness: Endianness { .little }
    var languageVersion: VersionTuple { VersionTuple(6, 0) }
    /// The first release with an official Android SDK.
    var compilerVersion: VersionTuple { VersionTuple(6, 3) }
}
