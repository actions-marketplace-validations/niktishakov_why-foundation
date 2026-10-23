import Foundation
import Testing
@testable import WhyFoundationCore

@Suite struct AnalyzerTests {
    /// Analyzes a root package made of `files` and `targets`, without SwiftPM.
    func analyze(
        _ files: [String: String],
        targets: [TargetNode],
        libraries: [String: [String]] = [:],
        platform: TargetPlatform = .android,
        swiftVersion: SwiftVersion? = SwiftVersion(6, 4, 1),
        allTargets: Bool = false,
        onDarwin: Bool = false
    ) throws -> Report {
        let package = try TemporaryPackage(files: files)
        let root = PackageNode(
            identity: "app", name: "app", path: package.path, products: libraries,
            targets: Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0) }), enabledTraits: [],
            libraryProducts: Set(libraries.keys)
        )
        let graph = PackageGraph(root: root, packagesByKey: ["app": root])
        return try withExtendedLifetime(package) {
            try Analyzer(
                graph: graph, platform: platform, allTargets: allTargets, swiftVersion: swiftVersion,
                manifestsEvaluatedOnDarwin: onDarwin
            ).run()
        }
    }

    @Test func privacyManifestOnly() throws {
        // swift-nio's NIOPosix: no Foundation import, only PrivacyInfo.xcprivacy (declared when the manifest is evaluated on macOS).
        let report = try analyze(
            ["Sources/NIOPosix/Socket.swift": "struct Socket {}\n"],
            targets: [target("NIOPosix", resources: ["PrivacyInfo.xcprivacy"])],
            onDarwin: true
        )
        let finding = try #require(report.findings.first)
        #expect(finding.causes == [.privacyManifest])
        #expect(finding.verdict == .privacyManifestOnly)
        let text = report.text()
        #expect(text.contains("1 only has a privacy manifest"))
        #expect(text.contains("── Only a privacy manifest: SwiftPM's resource accessor imports Foundation ──"))
        #expect(text.contains("(swiftlang/swift-package-manager#9792)"))
        #expect(text.contains("don't add it when you build on a Linux host."))
        #expect(!(try analyze(
            ["Sources/NIOPosix/Socket.swift": "struct Socket {}\n"],
            targets: [target("NIOPosix", resources: ["PrivacyInfo.xcprivacy"])]
        ).text().contains("Linux host")))
    }

    @Test func privacyManifestWithAnImportOrOtherResources() throws {
        // swift-crypto's CryptoBoringWrapper also imports Foundation: the code still has to change.
        let withImport = try analyze(
            ["Sources/Wrapper/AEAD.swift": "import Foundation\n"],
            targets: [target("Wrapper", resources: ["PrivacyInfo.xcprivacy"])]
        )
        #expect(withImport.findings.first?.verdict == .likelyEasy)
        #expect(withImport.findings.first?.causes.first == .privacyManifest)

        let otherResources = try analyze(
            ["Sources/Assets/Assets.swift": "struct Assets {}\n"],
            targets: [target("Assets", resources: ["PrivacyInfo.xcprivacy", "data.json"])]
        )
        #expect(otherResources.findings.first?.causes == [.resourceBundle])
        #expect(otherResources.findings.first?.verdict == .likelyEasy)
    }

    @Test func onlyLibraryProductsByDefault() throws {
        // swift-argument-parser: examples and tools import Foundation, the library doesn't.
        let files = [
            "Sources/ArgumentParser/Parser.swift": "import ArgumentParserToolInfo\n",
            "Sources/ArgumentParserToolInfo/Info.swift": "public struct Info {}\n",
            "Sources/count-lines/main.swift": "import Foundation\nlet handle = FileHandle.standardInput\n",
            "Sources/TestHelpers/Helpers.swift": "import Foundation\n",
        ]
        let targets = [
            target("ArgumentParser", dependencies: [.byName("ArgumentParserToolInfo", condition: DependencyCondition())]),
            target("ArgumentParserToolInfo"),
            target("count-lines", kind: .executable),
            target("TestHelpers"),
        ]
        let libraries = ["ArgumentParser": ["ArgumentParser"]]
        let report = try analyze(files, targets: targets, libraries: libraries)
        #expect(report.findings.isEmpty)
        #expect(report.skippedTargets == ["TestHelpers", "count-lines"])
        #expect(report.text().contains(
            "Not checked: 2 targets that no library product includes, such as examples and tools: TestHelpers, count-lines. Check them with --all-targets."
        ))

        let all = try analyze(files, targets: targets, libraries: libraries, allTargets: true)
        #expect(all.findings.map(\.target).sorted() == ["TestHelpers", "count-lines"])
        #expect(all.skippedTargets.isEmpty)
    }

    @Test func ownTypeInADependencyIsNotFoundations() throws {
        // swift-metrics: CoreMetrics declares its own Timer, and MetricsTestKit uses it.
        let report = try analyze([
            "Sources/CoreMetrics/Metrics.swift": "public final class Timer {}\n",
            "Sources/MetricsTestKit/TestMetrics.swift": """
            import Foundation
            import CoreMetrics
            let lock = NSLock()
            let timer = Timer()
            """,
        ], targets: [
            target("CoreMetrics"),
            target("MetricsTestKit", dependencies: [.byName("CoreMetrics", condition: DependencyCondition())]),
        ])
        let finding = try #require(report.findings.first { $0.target == "MetricsTestKit" })
        #expect(finding.fullFoundationAPIs == ["corelibsOnly": ["NSLock"]])
    }

    @Test func ownTypeInTheSameTarget() throws {
        // swift-parsing declares a parser called Pipe.
        let report = try analyze([
            "Sources/Parsing/Pipe.swift": """
            import Foundation
            public struct Pipe<Upstream, Downstream> {}
            extension Pipe: Sendable {}
            """,
        ], targets: [target("Parsing")])
        #expect(report.findings.map(\.verdict) == [.likelyEasy])
    }

    @Test func ownTypeWrappingFoundations() throws {
        // OpenCombine declares its own Timer on top of Foundation.Timer.
        let report = try analyze([
            "Sources/OpenCombineFoundation/Portability.swift": """
            import Foundation
            internal struct Timer {
                fileprivate typealias UnderlyingTimer = Foundation.Timer
            }
            """,
        ], targets: [target("OpenCombineFoundation")])
        #expect(report.findings.first?.fullFoundationAPIs == ["corelibsOnly": ["Timer"]])
    }

    @Test func ownMembersWithTheSameName() throws {
        let report = try analyze([
            "Sources/Text/Text.swift": """
            import Foundation
            struct Token {
                var range: Range<Int>
                func trimmingCharacters(in set: Set<Character>) -> Token { self }
            }
            func clean(_ token: Token, _ text: String) {
                _ = token.trimmingCharacters(in: [" "])
                _ = text.range(of: "x")
            }
            """,
        ], targets: [target("Text")])
        #expect(report.findings.first?.fullFoundationAPIs == ["corelibsOnly": ["range(of:)"]])
    }

    @Test func oneLineFix() throws {
        let files = [
            "Sources/Repeat/Repeater.swift": """
            import Foundation
            let queue = DispatchQueue(label: "repeater")
            func describe(_ stat: Int) -> String { "\\(stat)" }
            """,
            "Sources/Repeat/Debouncer.swift": """
            import Foundation
            let deadline = DispatchTime.now()
            """,
        ]
        let report = try analyze(files, targets: [target("Repeat")])
        let finding = try #require(report.findings.first)
        #expect(finding.verdict == .oneLineFix)
        #expect(finding.oneLineFixes == [OneLineFix(
            kind: .dispatch, suggestion: "add `import Dispatch`", symbols: ["DispatchQueue", "DispatchTime"],
            files: ["Sources/Repeat/Debouncer.swift", "Sources/Repeat/Repeater.swift"]
        )])
        #expect(report.text().contains("  fix: add `import Dispatch` in 2 files (DispatchQueue, DispatchTime)"))
    }

    @Test func libcFixDependsOnThePlatform() throws {
        let files = ["Sources/Rainbow/Rainbow.swift": "import Foundation\nlet isTerminal = isatty(1) != 0\n"]
        let android = try analyze(files, targets: [target("Rainbow")], platform: .android)
        let linux = try analyze(files, targets: [target("Rainbow")], platform: .linux)
        #expect(android.findings.first?.oneLineFixes.map(\.suggestion) == ["add `import Android`"])
        #expect(linux.findings.first?.oneLineFixes.first?.suggestion.hasPrefix("add `import Glibc`") == true)
        #expect(android.text().contains("  fix: add `import Android` in Sources/Rainbow/Rainbow.swift (isatty)"))
    }

    @Test func darwinWithoutAnAndroidBranch() throws {
        // Commander: fine on Linux, but imports Darwin on Android.
        let files = ["Sources/Commander/Error.swift": """
        #if os(Linux)
        import Glibc
        #else
        import Darwin
        #endif
        import Foundation
        """]
        let android = try analyze(files, targets: [target("Commander")], platform: .android)
        #expect(android.findings.first?.verdict == .appleOnly)
        #expect(android.text().contains("  hint: only Darwin is Apple-only here; an `#elseif canImport(Android)` branch"))
        let linux = try analyze(files, targets: [target("Commander")], platform: .linux)
        #expect(linux.findings.first?.verdict == .likelyEasy)
        #expect(!linux.text().contains("hint:"))
    }

    @Test func characterSetDependsOnTheSwiftVersion() throws {
        // Splash: CharacterSet is in FoundationEssentials on main, not in 6.4.x.
        let files = ["Sources/Splash/Tokenizer.swift": "import Foundation\nlet delimiters = CharacterSet(charactersIn: \".,\")\n"]
        let release = try analyze(files, targets: [target("Splash")], swiftVersion: SwiftVersion(6, 4, 1))
        #expect(release.findings.first?.verdict == .needsFullFoundation)
        #expect(release.swiftVersion == "6.4.1")
        #expect(release.versionDependentAPIs == ["CharacterSet"])
        #expect(release.text().hasSuffix("""
        CharacterSet counts as missing: FoundationEssentials has it from Swift 6.5 (on swift-foundation main since #2314). \
        Checked against Swift 6.4.1; change it with --swift-version.
        """))

        let main = try analyze(files, targets: [target("Splash")], swiftVersion: SwiftVersion(6, 5, isDevelopment: true))
        #expect(main.findings.first?.verdict == .likelyEasy)
        #expect(main.text().contains("CharacterSet doesn't count: FoundationEssentials has it from Swift 6.5"))

        let unknown = try analyze(files, targets: [target("Splash")], swiftVersion: nil)
        #expect(unknown.findings.first?.verdict == .needsFullFoundation)
        #expect(unknown.text().hasSuffix("The Swift version is unknown; change it with --swift-version."))
    }
}
