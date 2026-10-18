import Foundation

/// Why a target pulls in the full Foundation.
public enum Cause: Codable, Equatable, Sendable {
    /// An active `import` of a heavy module in one of the target's source files.
    case `import`(file: String, HeavyImport)
    /// The target has resources, so SwiftPM generates `resource_bundle_accessor.swift`,
    /// which imports Foundation.
    case resourceBundle
}

/// How hard it is to keep a target from pulling in Foundation.
public enum Verdict: String, Codable, Sendable {
    /// Imports an Apple-only framework: the target doesn't build for Android anyway.
    case appleOnly
    /// Uses APIs that exist only in the full Foundation, such as `URLSession`.
    case needsFullFoundation
    /// No full-Foundation APIs found: switching to `FoundationEssentials` looks straightforward.
    case likelyEasy
}

/// A target reachable from the analyzed entry points that pulls in Foundation.
public struct Finding: Codable, Sendable {
    public var package: String
    public var target: String
    /// The dependency path from an entry point to this target, entry point first.
    public var chain: [ChainStep]
    public var causes: [Cause]
    public var verdict: Verdict
    /// Apple-only modules the target imports in code that is active on the analyzed platform.
    public var appleOnlyImports: [String]
    /// Full-Foundation APIs the target uses, by `FullFoundationAPI` raw value.
    public var fullFoundationAPIs: [String: [String]]
}

/// A reachable target that doesn't import Foundation but imports an Apple-only framework.
public struct AppleOnlyTarget: Codable, Sendable {
    public var package: String
    public var target: String
    public var chain: [ChainStep]
    public var modules: [String]
}

public struct ChainStep: Codable, Equatable, Sendable {
    public var package: String
    public var target: String
    /// The product the previous step depends on to reach this target, if any.
    public var viaProduct: String?
}

public struct Report: Codable, Sendable {
    public var platform: String
    public var entryPoints: [String]
    public var findings: [Finding]
    /// Targets that don't pull in Foundation but won't build for the platform.
    public var appleOnlyTargets: [AppleOnlyTarget]
    /// Binary targets in the graph: their imports cannot be inspected.
    public var binaryTargets: [String]
}

public enum AnalysisError: Error, CustomStringConvertible {
    case unknownProduct(String, available: [String])

    public var description: String {
        switch self {
        case .unknownProduct(let name, let available):
            "No product named '\(name)' in the root package. Products: \(available.sorted().joined(separator: ", "))"
        }
    }
}

public struct Analyzer {
    public var graph: PackageGraph
    public var platform: TargetPlatform
    public var includeTests: Bool

    public init(graph: PackageGraph, platform: TargetPlatform, includeTests: Bool = false) {
        self.graph = graph
        self.platform = platform
        self.includeTests = includeTests
    }

    private struct Key: Hashable {
        var package: String
        var target: String
    }

    public func run(product: String? = nil) throws -> Report {
        let root = graph.root
        let entryNames: [String]
        if let product {
            guard let targets = root.products[product] else {
                throw AnalysisError.unknownProduct(product, available: Array(root.products.keys))
            }
            entryNames = targets
        } else {
            entryNames = root.targets.values
                .filter { $0.isShipped && ($0.kind != .test || includeTests) }
                .map(\.name)
                .sorted()
        }

        // Breadth-first, so each finding gets the shortest chain from an entry point.
        var parents: [Key: (parent: Key?, viaProduct: String?)] = [:]
        var queue: [Key] = []
        for name in entryNames {
            let key = Key(package: root.identity, target: name)
            parents[key] = (nil, nil)
            queue.append(key)
        }

        var visitOrder: [Key] = []
        // The targets each target depends on, for the names visible in it.
        var dependencies: [Key: [Key]] = [:]
        var binaryTargets: [String] = []
        var index = 0
        while index < queue.count {
            let key = queue[index]
            index += 1
            guard let package = graph.package(named: key.package),
                  let target = package.targets[key.target]
            else { continue }
            if target.kind == .binary {
                binaryTargets.append("\(package.identity) › \(target.name)")
                continue
            }
            guard target.isShipped else { continue }
            visitOrder.append(key)

            for dependency in target.dependencies {
                let condition = dependency.condition
                if let platforms = condition.platforms, !platforms.contains(platform.packageManifestName) {
                    continue
                }
                if let traits = condition.traits, package.enabledTraits.isDisjoint(with: traits) {
                    continue
                }
                for (next, viaProduct) in resolve(dependency, from: package) {
                    dependencies[key, default: []].append(next)
                    if parents[next] == nil {
                        parents[next] = (key, viaProduct)
                        queue.append(next)
                    }
                }
            }
        }

        let graphModules = Set(graph.packages.flatMap { $0.targets.keys })

        var scans: [Key: TargetScan] = [:]
        for key in visitOrder {
            guard let package = graph.package(named: key.package),
                  let target = package.targets[key.target]
            else { continue }
            let configuration = PlatformBuildConfiguration(
                platform: platform,
                graphModules: graphModules,
                customConditions: package.enabledTraits.union(target.activeDefines(for: platform))
            )
            scans[key] = Self.scan(target, in: package, configuration: configuration)
        }

        // Names declared by a target and by everything it depends on: a type of the package's own
        // called `Timer` isn't Foundation's.
        func names(visibleIn key: Key) -> Set<String> {
            var names: Set<String> = []
            var stack = [key]
            var seen: Set<Key> = [key]
            while let next = stack.popLast() {
                names.formUnion(scans[next]?.declaredNames ?? [])
                for dependency in dependencies[next] ?? [] where seen.insert(dependency).inserted {
                    stack.append(dependency)
                }
            }
            return names
        }

        var findings: [Finding] = []
        var appleOnlyTargets: [AppleOnlyTarget] = []
        for key in visitOrder {
            guard let package = graph.package(named: key.package),
                  let target = package.targets[key.target],
                  var scan = scans[key]
            else { continue }
            if !scan.causes.isEmpty {
                scan.removeAPIs(declaredIn: names(visibleIn: key))
            }

            var chain: [ChainStep] = []
            var cursor: Key? = key
            while let current = cursor, let entry = parents[current] {
                chain.append(ChainStep(package: current.package, target: current.target, viaProduct: entry.viaProduct))
                cursor = entry.parent
            }
            chain.reverse()

            if scan.causes.isEmpty {
                if !scan.appleOnlyImports.isEmpty {
                    appleOnlyTargets.append(AppleOnlyTarget(
                        package: package.identity, target: target.name, chain: chain, modules: scan.appleOnlyImports
                    ))
                }
                continue
            }

            let verdict: Verdict = if !scan.appleOnlyImports.isEmpty {
                .appleOnly
            } else if !scan.fullFoundationAPIs.isEmpty {
                .needsFullFoundation
            } else {
                .likelyEasy
            }
            findings.append(Finding(
                package: package.identity,
                target: target.name,
                chain: chain,
                causes: scan.causes,
                verdict: verdict,
                appleOnlyImports: scan.appleOnlyImports,
                fullFoundationAPIs: Dictionary(uniqueKeysWithValues: scan.fullFoundationAPIs.map { ($0.key.rawValue, $0.value.sorted()) })
            ))
        }

        return Report(
            platform: platform.rawValue,
            entryPoints: entryNames,
            findings: findings,
            appleOnlyTargets: appleOnlyTargets,
            binaryTargets: binaryTargets.sorted()
        )
    }

    /// The targets a dependency stands for, with the product it goes through.
    private func resolve(_ dependency: Dependency, from package: PackageNode) -> [(Key, String?)] {
        switch dependency {
        case .target(let name, _):
            return [(Key(package: package.identity, target: name), nil)]
        case .byName(let name, _):
            if package.targets[name] != nil {
                return [(Key(package: package.identity, target: name), nil)]
            }
            return productTargets(name, packageHint: nil)
        case .product(let name, let packageName, _):
            return productTargets(name, packageHint: packageName)
        }
    }

    private func productTargets(_ product: String, packageHint: String?) -> [(Key, String?)] {
        let candidates: [PackageNode]
        if let packageHint, let package = graph.package(named: packageHint) {
            candidates = [package]
        } else {
            candidates = graph.packages.filter { $0.products[product] != nil }
        }
        for package in candidates {
            if let targets = package.products[product] {
                return targets.map { (Key(package: package.identity, target: $0), product) }
            }
        }
        return []
    }

    struct TargetScan {
        var causes: [Cause] = []
        var appleOnlyImports: [String] = []
        var fullFoundationAPIs: [FullFoundationAPI: Set<String>] = [:]
        var declaredNames: Set<String> = []

        /// Drops the APIs whose names the code declares itself.
        mutating func removeAPIs(declaredIn names: Set<String>) {
            for (api, symbols) in fullFoundationAPIs {
                let remaining = symbols.filter { !FullFoundationAPI.isShadowed($0, by: names) }
                fullFoundationAPIs[api] = remaining.isEmpty ? nil : remaining
            }
        }
    }

    static func scan(
        _ target: TargetNode,
        in package: PackageNode,
        configuration: PlatformBuildConfiguration
    ) -> TargetScan {
        let directory = SourceLocator.directory(for: target, in: package)
        let files = SourceLocator.swiftFiles(for: target, in: directory)
        var result = TargetScan()
        // Listed first: unlike an import, it is invisible in the sources.
        if !files.isEmpty, target.hasDeclaredResources {
            result.causes.append(.resourceBundle)
        }

        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let relativePath = file.path.replacingOccurrences(of: package.path.path + "/", with: "")
            let fileScan = ImportScanner.scan(source, configuration: configuration)
            for heavyImport in fileScan.heavyImports {
                result.causes.append(.import(file: relativePath, heavyImport))
            }
            for module in fileScan.appleOnlyImports where !result.appleOnlyImports.contains(module) {
                result.appleOnlyImports.append(module)
            }
            for (api, symbols) in fileScan.fullFoundationAPIs {
                result.fullFoundationAPIs[api, default: []].formUnion(symbols)
            }
            result.declaredNames.formUnion(fileScan.declaredNames)
        }
        return result
    }
}
