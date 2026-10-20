extension Report {
    /// How many causes the text report lists per target unless `verbose` is set.
    static let causesShownPerTarget = 3

    /// A human-readable summary, grouped by how hard each target is to fix.
    public func text(verbose: Bool = false) -> String {
        var lines: [String] = []
        if findings.isEmpty {
            lines.append("✓ Nothing in the \(platform) build imports Foundation. Only FoundationEssentials ends up in the app.")
        } else {
            let count = findings.count == 1 ? "1 target pulls" : "\(findings.count) targets pull"
            lines.append("✗ \(count) the full Foundation (and ICU) into the \(platform) build.")
            let summary = Verdict.allCasesInReportOrder.compactMap { verdict -> String? in
                let n = findings.filter { $0.verdict == verdict }.count
                return n == 0 ? nil : "\(n) \(verdict.summaryLabel(count: n))"
            }
            lines.append("  " + summary.joined(separator: " · "))

            for verdict in Verdict.allCasesInReportOrder {
                let group = findings.filter { $0.verdict == verdict }
                guard !group.isEmpty else { continue }
                lines.append("")
                lines.append("── \(verdict.heading) ──")
                for finding in group {
                    lines.append("")
                    lines.append(contentsOf: block(for: finding, verbose: verbose))
                }
            }
        }

        if !appleOnlyTargets.isEmpty {
            lines.append("")
            lines.append("── Don't import Foundation, but import Apple-only frameworks (won't build for \(platform)) ──")
            for target in appleOnlyTargets {
                lines.append("  \(target.package) › \(target.target): \(target.modules.joined(separator: ", "))")
                if let hint = darwinHint(target.modules) {
                    lines.append("    " + hint)
                }
            }
        }
        if !binaryTargets.isEmpty {
            lines.append("")
            lines.append("Not inspected (binary targets): " + binaryTargets.joined(separator: ", "))
        }
        if !versionDependentAPIs.isEmpty {
            lines.append("")
            lines.append(versionNote)
        }
        return lines.joined(separator: "\n")
    }

    /// Code like `#if os(Linux) import Glibc #else import Darwin #endif` imports Darwin on Android. When that
    /// is the only Apple-only import, an Android branch is often all the target needs.
    private func darwinHint(_ modules: [String]) -> String? {
        guard platform == TargetPlatform.android.rawValue, modules == ["Darwin"] else { return nil }
        return "hint: only Darwin is Apple-only here; an `#elseif canImport(Android)` branch with `import Android` may be enough"
    }

    /// Says how the APIs that only newer FoundationEssentials releases have were counted.
    private var versionNote: String {
        let notes = versionDependentAPIs.compactMap { symbol -> String? in
            guard let added = FullFoundationAPI.addedToEssentials[symbol] else { return nil }
            let counted = swiftVersion.flatMap { SwiftVersion($0) }.map { $0 < added.version } ?? true
            let status = counted ? "counts as missing" : "doesn't count"
            return "\(symbol) \(status): FoundationEssentials has it from Swift \(added.version) (\(added.change))."
        }
        let checked = swiftVersion.map { "Checked against Swift \($0)" } ?? "The Swift version is unknown"
        return (notes + ["\(checked); change it with --swift-version."]).joined(separator: " ")
    }

    private func block(for finding: Finding, verbose: Bool) -> [String] {
        var lines = ["\(finding.package) › \(finding.target)"]
        lines.append("  path: " + finding.chain.map(\.label).joined(separator: " → "))
        if !finding.appleOnlyImports.isEmpty {
            lines.append("  imports: " + finding.appleOnlyImports.joined(separator: ", "))
            if let hint = darwinHint(finding.appleOnlyImports) {
                lines.append("  " + hint)
            }
        }
        let apis = FullFoundationAPI.allCases.compactMap { api -> String? in
            guard let symbols = finding.fullFoundationAPIs[api.rawValue], !symbols.isEmpty else { return nil }
            return "\(symbols.joined(separator: ", ")) (\(api.label))"
        }
        if !apis.isEmpty {
            lines.append("  uses: " + apis.joined(separator: "; "))
        }
        for fix in finding.oneLineFixes {
            let files = fix.files.count == 1 ? fix.files[0] : "\(fix.files.count) files"
            lines.append("  fix: \(fix.suggestion) in \(files) (\(fix.symbols.joined(separator: ", ")))")
            if verbose, fix.files.count > 1 {
                lines.append(contentsOf: fix.files.map { "    \($0)" })
            }
        }

        // For Apple-only targets the individual imports don't matter.
        let limit = finding.verdict == .appleOnly ? 1 : Self.causesShownPerTarget
        let shown = verbose ? finding.causes : Array(finding.causes.prefix(limit))
        for cause in shown {
            switch cause {
            case .import(let file, let heavyImport):
                let exported = heavyImport.isExported ? "@_exported " : ""
                lines.append("  \(file):\(heavyImport.line)  \(exported)import \(heavyImport.module.rawValue)")
            case .resourceBundle:
                lines.append("  resources in Package.swift  (SwiftPM's generated resource accessor imports Foundation)")
            }
        }
        let hidden = finding.causes.count - shown.count
        if hidden > 0 {
            lines.append("  … and \(hidden) more (--verbose)")
        }
        return lines
    }
}

extension Verdict {
    static let allCasesInReportOrder: [Verdict] = [.likelyEasy, .oneLineFix, .needsFullFoundation, .appleOnly]

    func summaryLabel(count: Int) -> String {
        let one = count == 1
        return switch self {
        case .likelyEasy: one ? "looks easy to fix" : "look easy to fix"
        case .oneLineFix: one ? "needs a one-line fix too" : "need a one-line fix too"
        case .needsFullFoundation: one ? "uses full-Foundation APIs" : "use full-Foundation APIs"
        case .appleOnly: one ? "imports Apple-only frameworks" : "import Apple-only frameworks"
        }
    }

    var heading: String {
        switch self {
        case .likelyEasy: "Likely easy: no APIs beyond FoundationEssentials found"
        case .oneLineFix: "Likely easy, plus a one-line fix: the code uses modules that Foundation re-exports"
        case .needsFullFoundation: "Use APIs that need the full Foundation"
        case .appleOnly: "Import Apple-only frameworks: won't build for this platform anyway"
        }
    }
}

extension FullFoundationAPI {
    var label: String {
        switch self {
        case .networking: "FoundationNetworking"
        case .formatting: "needs ICU"
        case .corelibsOnly: "not in FoundationEssentials"
        }
    }
}

extension ChainStep {
    var label: String {
        if let viaProduct, viaProduct != target {
            return "\(target) (\(package), product \(viaProduct))"
        }
        return viaProduct == nil ? target : "\(target) (\(package))"
    }
}
