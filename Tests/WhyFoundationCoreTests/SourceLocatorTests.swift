import Foundation
import Testing
@testable import WhyFoundationCore

/// A package directory with the given files, removed when the value is deinitialized.
final class TemporaryPackage {
    let path: URL

    init(files: [String: String]) throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("why-foundation-tests-\(UUID().uuidString)")
        for (relativePath, contents) in files {
            let url = path.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: path)
    }
}

func target(_ name: String, dependencies: [Dependency] = []) -> TargetNode {
    TargetNode(
        name: name, kind: .regular, customPath: nil, sources: nil, exclude: [],
        hasDeclaredResources: false, dependencies: dependencies, swiftDefines: []
    )
}

@Suite struct SourceLocatorTests {
    @Test func skipsDocCCatalogs() throws {
        let package = try TemporaryPackage(files: [
            "Sources/Core/Core.swift": "public struct Core {}\n",
            "Sources/Core/Documentation.docc/Tutorials/Resources/step01.swift": "import Foundation\n",
            "Sources/Core/Documentation.docc/Core.md": "# Core\n",
        ])
        let directory = package.path.appendingPathComponent("Sources/Core")
        let files = SourceLocator.swiftFiles(for: target("Core"), in: directory)
        #expect(files.map(\.lastPathComponent) == ["Core.swift"])
    }
}
