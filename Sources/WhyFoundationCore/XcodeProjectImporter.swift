import Foundation

public enum XcodeProjectError: Error, CustomStringConvertible {
    case unreadableProject(URL, String)
    case noPackageDependencies(URL)

    public var description: String {
        switch self {
        case .unreadableProject(let url, let reason):
            "Could not read \(url.lastPathComponent): \(reason)"
        case .noPackageDependencies(let url):
            "\(url.lastPathComponent) has no Swift package dependencies to analyze."
        }
    }
}

/// Turns an Xcode project's Swift package dependencies into a SwiftPM package that the
/// analysis can load: one target per Xcode target, depending on the same products.
///
/// Only package dependencies are covered; the app's own sources live in the Xcode project
/// and aren't scanned.
public enum XcodeProjectImporter {
    struct RemotePackage: Equatable {
        var url: String
        var requirement: String

        var identity: String {
            var name = url.split(separator: "/").last.map(String.init) ?? url
            if name.hasSuffix(".git") { name.removeLast(4) }
            return name.lowercased()
        }
    }

    struct XcodeTarget: Equatable {
        var name: String
        var isTest: Bool
        /// Product name and the identity of the package that provides it.
        var products: [(name: String, package: String)]

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name == rhs.name && lhs.isTest == rhs.isTest
                && lhs.products.map(\.name) == rhs.products.map(\.name)
                && lhs.products.map(\.package) == rhs.products.map(\.package)
        }
    }

    struct Project {
        var remotePackages: [RemotePackage]
        /// Absolute paths of local packages.
        var localPackages: [URL]
        var targets: [XcodeTarget]
    }

    /// Writes the wrapper package and returns its directory. The directory is reused between
    /// runs, so SwiftPM's checkouts stay cached.
    public static func makeWrapperPackage(
        for projectURL: URL,
        includeTests: Bool,
        swiftExecutable: String = "swift"
    ) throws -> URL {
        let objects = try loadObjects(projectURL)
        let project = parse(
            objects: objects,
            projectDirectory: projectURL.deletingLastPathComponent(),
            localProducts: { try? localProducts(at: $0, swiftExecutable: swiftExecutable) }
        )
        let targets = project.targets.filter { (includeTests || !$0.isTest) && !$0.products.isEmpty }
        guard !targets.isEmpty else {
            throw XcodeProjectError.noPackageDependencies(projectURL)
        }

        let directory = wrapperDirectory(for: projectURL)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory.appendingPathComponent("Sources"))
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifest(project: project, targets: targets)
            .write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        for target in targets {
            let sources = directory.appendingPathComponent("Sources").appendingPathComponent(sanitized(target.name))
            try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
            try "// Stand-in for the Xcode target \(target.name).\n"
                .write(to: sources.appendingPathComponent("Placeholder.swift"), atomically: true, encoding: .utf8)
        }

        // Pin the same versions Xcode resolved.
        let resolved = projectURL
            .appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let wrapperResolved = directory.appendingPathComponent("Package.resolved")
        try? fileManager.removeItem(at: wrapperResolved)
        if fileManager.fileExists(atPath: resolved.path) {
            try fileManager.copyItem(at: resolved, to: wrapperResolved)
        }
        return directory
    }

    static func loadObjects(_ projectURL: URL) throws -> [String: [String: Any]] {
        let pbxproj = projectURL.appendingPathComponent("project.pbxproj")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        process.arguments = ["-convert", "json", "-o", "-", pbxproj.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw XcodeProjectError.unreadableProject(projectURL, "plutil is required to read Xcode projects (macOS only)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let objects = root["objects"] as? [String: [String: Any]]
        else {
            throw XcodeProjectError.unreadableProject(projectURL, "project.pbxproj is not a valid property list")
        }
        return objects
    }

    static func parse(
        objects: [String: [String: Any]],
        projectDirectory: URL,
        localProducts: (URL) -> (identity: String, products: [String])?
    ) -> Project {
        var remoteByID: [String: RemotePackage] = [:]
        var localByID: [String: URL] = [:]
        for (id, object) in objects {
            switch object["isa"] as? String {
            case "XCRemoteSwiftPackageReference":
                if let url = object["repositoryURL"] as? String {
                    remoteByID[id] = RemotePackage(
                        url: url,
                        requirement: requirement(object["requirement"] as? [String: Any] ?? [:])
                    )
                }
            case "XCLocalSwiftPackageReference":
                if let path = object["relativePath"] as? String {
                    localByID[id] = projectDirectory.appendingPathComponent(path).standardizedFileURL
                }
            default:
                break
            }
        }

        // Product dependencies on local packages often carry no package reference.
        var localIdentityByProduct: [String: String] = [:]
        var localIdentityByPath: [URL: String] = [:]
        for path in Set(localByID.values) {
            if let info = localProducts(path) {
                localIdentityByPath[path] = info.identity
                for product in info.products {
                    localIdentityByProduct[product] = info.identity
                }
            }
        }

        var targets: [XcodeTarget] = []
        for object in objects.values where object["isa"] as? String == "PBXNativeTarget" {
            guard let name = object["name"] as? String else { continue }
            let productType = object["productType"] as? String ?? ""
            var products: [(name: String, package: String)] = []
            for id in object["packageProductDependencies"] as? [String] ?? [] {
                guard let dependency = objects[id], let product = dependency["productName"] as? String else { continue }
                let packageID = dependency["package"] as? String
                if let packageID, let remote = remoteByID[packageID] {
                    products.append((product, remote.identity))
                } else if let packageID, let path = localByID[packageID], let identity = localIdentityByPath[path] {
                    products.append((product, identity))
                } else if let identity = localIdentityByProduct[product] {
                    products.append((product, identity))
                }
            }
            targets.append(XcodeTarget(name: name, isTest: productType.contains("test"), products: products))
        }

        return Project(
            remotePackages: remoteByID.values.sorted { $0.url < $1.url },
            localPackages: Array(Set(localByID.values)).sorted { $0.path < $1.path },
            targets: targets.sorted { $0.name < $1.name }
        )
    }

    /// The SwiftPM spelling of an Xcode package requirement.
    static func requirement(_ object: [String: Any]) -> String {
        let minimum = object["minimumVersion"] as? String ?? "0.0.0"
        switch object["kind"] as? String {
        case "upToNextMinorVersion": return ".upToNextMinor(from: \"\(minimum)\")"
        case "exactVersion": return "exact: \"\(object["version"] as? String ?? minimum)\""
        case "versionRange": return "\"\(minimum)\"..<\"\(object["maximumVersion"] as? String ?? minimum)\""
        case "branch": return "branch: \"\(object["branch"] as? String ?? "main")\""
        case "revision": return "revision: \"\(object["revision"] as? String ?? "")\""
        default: return "from: \"\(minimum)\""
        }
    }

    static func manifest(project: Project, targets: [XcodeTarget]) -> String {
        var lines = [
            "// swift-tools-version: 6.0",
            "// Generated by why-foundation from an Xcode project. Edits are overwritten.",
            "import PackageDescription",
            "",
            "let package = Package(",
            "    name: \"xcode-project\",",
            "    dependencies: [",
        ]
        for package in project.remotePackages {
            lines.append("        .package(url: \"\(package.url)\", \(package.requirement)),")
        }
        for path in project.localPackages {
            lines.append("        .package(path: \"\(path.path)\"),")
        }
        lines.append("    ],")
        lines.append("    targets: [")
        for target in targets {
            let products = target.products
                .map { ".product(name: \"\($0.name)\", package: \"\($0.package)\")" }
                .joined(separator: ", ")
            lines.append("        .target(name: \"\(sanitized(target.name))\", dependencies: [\(products)]),")
        }
        lines.append("    ]")
        lines.append(")")
        return lines.joined(separator: "\n") + "\n"
    }

    static func sanitized(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }

    static func wrapperDirectory(for projectURL: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        // A stable, readable key per project path.
        let path = projectURL.standardizedFileURL.path
        var hash: UInt64 = 1469598103934665603
        for byte in path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        let name = projectURL.deletingPathExtension().lastPathComponent
        return caches
            .appendingPathComponent("why-foundation")
            .appendingPathComponent("\(sanitized(name))-\(String(hash, radix: 16).prefix(8))")
    }

    /// The identity and product names of a local package.
    static func localProducts(at path: URL, swiftExecutable: String) throws -> (identity: String, products: [String]) {
        let manifest = try GraphLoader.dumpPackage(at: path, swiftExecutable: swiftExecutable)
        let products = (manifest["products"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return (path.lastPathComponent.lowercased(), products)
    }
}
