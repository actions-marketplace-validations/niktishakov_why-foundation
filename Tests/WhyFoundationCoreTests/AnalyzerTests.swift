import Foundation
import Testing
@testable import WhyFoundationCore

@Suite struct AnalyzerTests {
    /// Analyzes a root package made of `files` and `targets`, without SwiftPM.
    func analyze(_ files: [String: String], targets: [TargetNode], platform: TargetPlatform = .android) throws -> Report {
        let package = try TemporaryPackage(files: files)
        let root = PackageNode(
            identity: "app", name: "app", path: package.path, products: [:],
            targets: Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0) }), enabledTraits: []
        )
        let graph = PackageGraph(root: root, packagesByKey: ["app": root])
        return try withExtendedLifetime(package) {
            try Analyzer(graph: graph, platform: platform).run()
        }
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
}
