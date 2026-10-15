import Foundation

/// A package in the resolved dependency graph, with the parts of its manifest the analysis needs.
public struct PackageNode: Sendable {
    public var identity: String
    public var name: String
    public var path: URL
    public var products: [String: [String]]
    public var targets: [String: TargetNode]
    /// Traits enabled for this package in the resolved graph; each is also a compilation condition.
    public var enabledTraits: Set<String>
}

public struct TargetNode: Sendable {
    public enum Kind: String, Sendable {
        case regular, executable, test, system, binary, plugin, macro
    }

    public var name: String
    public var kind: Kind
    public var customPath: String?
    public var sources: [String]?
    public var exclude: [String]
    public var hasDeclaredResources: Bool
    public var dependencies: [Dependency]
    /// `swiftSettings: [.define(...)]`, with the platforms each one is limited to.
    public var swiftDefines: [SwiftDefine]

    /// The compilation conditions this target's `define` settings set for `platform`, in a release build.
    func activeDefines(for platform: TargetPlatform) -> Set<String> {
        Set(swiftDefines.filter { define in
            if let platforms = define.platforms, !platforms.contains(platform.packageManifestName) { return false }
            return define.configuration != "debug"
        }.map(\.name))
    }

    /// Kinds whose code never ends up in the app.
    var isShipped: Bool {
        switch kind {
        case .regular, .executable, .test: true
        case .system, .binary, .plugin, .macro: false
        }
    }
}

public struct SwiftDefine: Sendable, Equatable {
    public var name: String
    public var platforms: [String]?
    /// `debug` or `release` when the define is limited to one configuration.
    public var configuration: String?
}

/// A `.when(...)` clause on a target dependency.
public struct DependencyCondition: Sendable, Equatable {
    public var platforms: [String]?
    public var traits: [String]?
}

public enum Dependency: Sendable {
    /// `"Name"`: a target of the same package, or a product with that name.
    case byName(String, condition: DependencyCondition)
    case target(String, condition: DependencyCondition)
    case product(String, package: String?, condition: DependencyCondition)

    var condition: DependencyCondition {
        switch self {
        case .byName(_, let condition), .target(_, let condition), .product(_, _, let condition): condition
        }
    }
}

public struct PackageGraph: Sendable {
    public var root: PackageNode
    /// All packages, keyed by lowercased identity and lowercased manifest name.
    var packagesByKey: [String: PackageNode]

    public var packages: [PackageNode] {
        var seen = Set<String>()
        return packagesByKey.values.filter { seen.insert($0.identity).inserted }
    }

    func package(named key: String) -> PackageNode? {
        packagesByKey[key.lowercased()]
    }
}

public enum GraphLoadingError: Error, CustomStringConvertible {
    case commandFailed(String, String)
    case unexpectedOutput(String)

    public var description: String {
        switch self {
        case .commandFailed(let command, let output): "`\(command)` failed:\n\(output)"
        case .unexpectedOutput(let command): "`\(command)` returned output that could not be read"
        }
    }
}

public enum GraphLoader {
    /// Resolves the package at `packagePath` and loads the manifests of every package in its graph.
    public static func load(packagePath: URL, swiftExecutable: String = "swift") throws -> PackageGraph {
        let tree = try runJSON(swiftExecutable, ["package", "show-dependencies", "--format", "json"], in: packagePath)
        guard let rootInfo = tree as? [String: Any] else {
            throw GraphLoadingError.unexpectedOutput("swift package show-dependencies")
        }

        var locations: [(identity: String, path: URL)] = []
        // A package can appear several times with different traits; SwiftPM enables their union.
        var requestedTraits: [String: Set<String>] = [:]
        var seen = Set<String>()
        func collect(_ node: [String: Any]) {
            guard let identity = node["identity"] as? String, let path = node["path"] as? String else { return }
            if seen.insert(identity).inserted {
                locations.append((identity, URL(fileURLWithPath: path)))
            }
            requestedTraits[identity, default: []].formUnion(node["traits"] as? [String] ?? [])
            for child in node["dependencies"] as? [[String: Any]] ?? [] {
                collect(child)
            }
        }
        collect(rootInfo)

        var packagesByKey: [String: PackageNode] = [:]
        var root: PackageNode?
        for (index, location) in locations.enumerated() {
            let manifest = try dumpPackage(at: location.path, swiftExecutable: swiftExecutable)
            let node = makePackage(
                identity: location.identity,
                path: location.path,
                manifest: manifest,
                requestedTraits: requestedTraits[location.identity] ?? []
            )
            packagesByKey[node.identity.lowercased()] = node
            packagesByKey[node.name.lowercased()] = packagesByKey[node.name.lowercased()] ?? node
            if index == 0 { root = node }
        }
        return PackageGraph(root: root!, packagesByKey: packagesByKey)
    }

    static func makePackage(
        identity: String,
        path: URL,
        manifest: [String: Any],
        requestedTraits: Set<String>
    ) -> PackageNode {
        var products: [String: [String]] = [:]
        for product in manifest["products"] as? [[String: Any]] ?? [] {
            if let name = product["name"] as? String {
                products[name] = product["targets"] as? [String] ?? []
            }
        }

        var targets: [String: TargetNode] = [:]
        for target in manifest["targets"] as? [[String: Any]] ?? [] {
            guard let name = target["name"] as? String else { continue }
            let kind = TargetNode.Kind(rawValue: target["type"] as? String ?? "") ?? .regular
            let resources = target["resources"] as? [Any] ?? []
            let dependencies = (target["dependencies"] as? [[String: Any]] ?? []).compactMap(parseDependency)
            targets[name] = TargetNode(
                name: name,
                kind: kind,
                customPath: target["path"] as? String,
                sources: target["sources"] as? [String],
                exclude: target["exclude"] as? [String] ?? [],
                hasDeclaredResources: !resources.isEmpty,
                dependencies: dependencies,
                swiftDefines: (target["settings"] as? [[String: Any]] ?? []).compactMap(parseSwiftDefine)
            )
        }

        return PackageNode(
            identity: identity,
            name: manifest["name"] as? String ?? identity,
            path: path,
            products: products,
            targets: targets,
            enabledTraits: expandTraits(requestedTraits, manifest: manifest)
        )
    }

    /// Adds the traits that the requested ones enable, transitively (`default` usually enables several).
    static func expandTraits(_ requested: Set<String>, manifest: [String: Any]) -> Set<String> {
        var definitions: [String: [String]] = [:]
        for trait in manifest["traits"] as? [[String: Any]] ?? [] {
            if let name = trait["name"] as? String {
                definitions[name] = trait["enabledTraits"] as? [String] ?? []
            }
        }
        var enabled = Set<String>()
        var pending = Array(requested)
        while let trait = pending.popLast() {
            guard enabled.insert(trait).inserted else { continue }
            pending.append(contentsOf: definitions[trait] ?? [])
        }
        return enabled
    }

    /// Parses one entry of a target's `settings` array if it is a Swift `define`.
    static func parseSwiftDefine(_ entry: [String: Any]) -> SwiftDefine? {
        guard entry["tool"] as? String == "swift",
              let kind = entry["kind"] as? [String: Any],
              let define = kind["define"] as? [String: Any],
              let value = define["_0"] as? String
        else { return nil }
        let condition = entry["condition"] as? [String: Any]
        // `-D` takes a bare name; drop a value if one was given.
        let name = value.split(separator: "=", maxSplits: 1).first.map(String.init) ?? value
        return SwiftDefine(
            name: name,
            platforms: condition?["platformNames"] as? [String],
            configuration: condition?["config"] as? String
        )
    }

    /// Parses one entry of a target's `dependencies` array as printed by `swift package dump-package`.
    static func parseDependency(_ entry: [String: Any]) -> Dependency? {
        func condition(_ value: Any?) -> DependencyCondition {
            let object = value as? [String: Any]
            return DependencyCondition(
                platforms: object?["platformNames"] as? [String],
                traits: object?["traits"] as? [String]
            )
        }
        if let values = entry["byName"] as? [Any], let name = values.first as? String {
            return .byName(name, condition: condition(values.dropFirst().first))
        }
        if let values = entry["target"] as? [Any], let name = values.first as? String {
            return .target(name, condition: condition(values.dropFirst().first))
        }
        if let values = entry["product"] as? [Any], let name = values.first as? String {
            let package = values.count > 1 ? values[1] as? String : nil
            return .product(name, package: package, condition: condition(values.count > 3 ? values[3] : nil))
        }
        return nil
    }

    /// The manifest of the package at `path`, as printed by `swift package dump-package`.
    static func dumpPackage(at path: URL, swiftExecutable: String) throws -> [String: Any] {
        guard let manifest = try runJSON(swiftExecutable, ["package", "dump-package"], in: path) as? [String: Any] else {
            throw GraphLoadingError.unexpectedOutput("swift package dump-package in \(path.path)")
        }
        return manifest
    }

    private static func runJSON(_ executable: String, _ arguments: [String], in directory: URL) throws -> Any {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        // Resolution can print a lot to stderr; a file keeps it from filling a pipe and stalling the process.
        let errorLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("why-foundation-\(UUID().uuidString).log")
        _ = FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorLog) }
        let errors = try FileHandle(forWritingTo: errorLog)
        defer { try? errors.close() }
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let errorData = (try? Data(contentsOf: errorLog)) ?? Data()

        let command = ([executable] + arguments).joined(separator: " ")
        guard process.terminationStatus == 0 else {
            throw GraphLoadingError.commandFailed(command, String(decoding: errorData, as: UTF8.self))
        }
        // SwiftPM may print progress lines before the JSON document.
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let json = try? JSONSerialization.jsonObject(with: data[start...])
        else {
            throw GraphLoadingError.unexpectedOutput(command)
        }
        return json
    }
}
