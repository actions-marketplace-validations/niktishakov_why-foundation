import ArgumentParser
import Foundation
import WhyFoundationCore

@main
struct WhyFoundation: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "why-foundation",
        abstract: "Find which dependencies pull the full Foundation, and with it ICU, into a non-Darwin build.",
        discussion: """
        On Android and Linux, `import Foundation` anywhere in the dependency graph adds \
        FoundationInternationalization and the ICU data (about 48 MB per Android ABI). \
        This tool lists every target that does it and the dependency path that leads there.
        """
    )

    @Option(name: .shortAndLong, help: "Path to a Swift package, an .xcodeproj, or a directory with one of them.")
    var packagePath: String = "."

    @Option(help: "Platform whose #if conditions and dependency conditions apply: \(TargetPlatform.allCases.map(\.rawValue).joined(separator: ", ")).")
    var platform: String = TargetPlatform.android.rawValue

    @Option(help: "Analyze only this product of the root package. By default, all non-test targets.")
    var product: String?

    @Flag(help: "Also analyze the root package's test targets.")
    var includeTests = false

    @Flag(help: "Print the report as JSON.")
    var json = false

    @Flag(help: "List every import, not just the first few per target.")
    var verbose = false

    @Option(help: "Swift release whose FoundationEssentials to check against, such as 6.4 or 6.5. Default: the version of `swift` on PATH.")
    var swiftVersion: String?

    func run() throws {
        guard let platform = TargetPlatform(rawValue: platform) else {
            throw ValidationError("Unknown platform '\(self.platform)'.")
        }
        var version: SwiftVersion?
        if let swiftVersion {
            guard let parsed = SwiftVersion(swiftVersion) else {
                throw ValidationError("Can't read Swift version '\(swiftVersion)'. Pass a version such as 6.4 or 6.5.")
            }
            version = parsed
        }
        let report: Report
        do {
            report = try analyze(platform: platform, swiftVersion: version ?? GraphLoader.swiftVersion())
        } catch let error as ValidationError {
            throw error
        } catch {
            // Exit with 2, not 1: a failed run must not look like "Foundation found".
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            throw ExitCode(ExitStatus.failure.rawValue)
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            print(report.text(verbose: verbose))
        }
        let status = ExitStatus(report: report)
        if status != .clean {
            throw ExitCode(status.rawValue)
        }
    }

    private func analyze(platform: TargetPlatform, swiftVersion: SwiftVersion?) throws -> Report {
        var path = URL(fileURLWithPath: packagePath).standardizedFileURL
        if let project = try xcodeProject(at: path) {
            if !json {
                print("Reading Swift package dependencies of \(project.lastPathComponent) (the app's own sources are not scanned).\n")
            }
            path = try XcodeProjectImporter.makeWrapperPackage(for: project, includeTests: includeTests)
        }
        let graph = try GraphLoader.load(packagePath: path)
        let analyzer = Analyzer(graph: graph, platform: platform, includeTests: includeTests, swiftVersion: swiftVersion)
        return try analyzer.run(product: product)
    }

    /// The Xcode project to analyze, if `path` is one or is a directory with one and no `Package.swift`.
    private func xcodeProject(at path: URL) throws -> URL? {
        if path.pathExtension == "xcodeproj" {
            return path
        }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: path.appendingPathComponent("Package.swift").path) else {
            return nil
        }
        let projects = (try? fileManager.contentsOfDirectory(at: path, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "xcodeproj" } ?? []
        switch projects.count {
        case 0: return nil
        case 1: return projects[0]
        default:
            let names = projects.map(\.lastPathComponent).sorted().joined(separator: ", ")
            throw ValidationError("Found several Xcode projects (\(names)). Pass one of them with --package-path.")
        }
    }
}
