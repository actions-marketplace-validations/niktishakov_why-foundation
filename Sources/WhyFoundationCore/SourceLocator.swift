import Foundation

/// Finds a target's Swift sources the way SwiftPM does.
enum SourceLocator {
    static func directory(for target: TargetNode, in package: PackageNode) -> URL {
        if let customPath = target.customPath {
            return package.path.appendingPathComponent(customPath)
        }
        let parents: [String] = switch target.kind {
        case .test: ["Tests", "Sources", "Source", "src", "srcs"]
        case .plugin: ["Plugins"]
        default: ["Sources", "Source", "src", "srcs"]
        }
        for parent in parents {
            let candidate = package.path.appendingPathComponent(parent).appendingPathComponent(target.name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
        }
        return package.path.appendingPathComponent("Sources").appendingPathComponent(target.name)
    }

    static func swiftFiles(for target: TargetNode, in directory: URL) -> [URL] {
        let roots = target.sources?.map { directory.appendingPathComponent($0) } ?? [directory]
        let excluded = target.exclude.map { directory.appendingPathComponent($0).standardizedFileURL.path }

        func isExcluded(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            return excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        // SwiftPM doesn't compile what is inside a DocC catalog, such as tutorial code.
        func isDocCCatalog(_ url: URL) -> Bool {
            url.pathExtension == "docc"
        }

        var files: [URL] = []
        for root in roots where !isExcluded(root) && !isDocCCatalog(root) {
            if root.pathExtension == "swift" {
                files.append(root)
                continue
            }
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in enumerator {
                if isExcluded(url) || isDocCCatalog(url) {
                    enumerator.skipDescendants()
                    continue
                }
                if url.pathExtension == "swift" {
                    files.append(url)
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
