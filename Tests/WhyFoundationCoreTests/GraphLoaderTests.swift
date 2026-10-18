import Foundation
import Testing
@testable import WhyFoundationCore

let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")

@Suite struct GraphLoaderTests {
    @Test func failureShowsOnlySwiftPMErrors() {
        let output = """
        Fetching https://github.com/pointfreeco/swift-clocks from cache
        Fetched https://github.com/pointfreeco/swift-clocks from cache (0.50s)
        Computing version for https://github.com/apple/swift-collections
        Creating working copy for https://github.com/OpenCombine/OpenCombine.git
        error: multiple packages ('swift-issue-reporting', 'xctest-dynamic-overlay') declare targets with a conflicting name: 'IssueReporting'
        /work/Package.swift:12:5: error: missing argument for parameter 'name' in call

        """
        let error = GraphLoadingError.commandFailed("swift package show-dependencies --format json", output)
        #expect(error.description == """
        `swift package show-dependencies --format json` failed:
        error: multiple packages ('swift-issue-reporting', 'xctest-dynamic-overlay') declare targets with a conflicting name: 'IssueReporting'
        /work/Package.swift:12:5: error: missing argument for parameter 'name' in call
        """)
    }

    @Test func graphErrorFromSwiftPM() throws {
        let error = #expect(throws: GraphLoadingError.self) {
            try GraphLoader.load(packagePath: fixtures.appendingPathComponent("conflict"))
        }
        let lines = try #require(error?.description.split(separator: "\n"))
        #expect(lines.count >= 2)
        #expect(lines.dropFirst().allSatisfy { $0.contains("error:") })
        #expect(lines.contains { $0.contains("'Shared'") })
    }

    @Test func exitStatus() {
        let empty = Report(platform: "android", entryPoints: [], findings: [], appleOnlyTargets: [], binaryTargets: [])
        #expect(ExitStatus(report: empty) == .clean)
        #expect(ExitStatus.foundationFound.rawValue == 1)
        #expect(ExitStatus.failure.rawValue == 2)
    }
}
