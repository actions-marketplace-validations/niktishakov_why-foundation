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
            }
        }
        if !binaryTargets.isEmpty {
            lines.append("")
            lines.append("Not inspected (binary targets): " + binaryTargets.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private func block(for finding: Finding, verbose: Bool) -> [String] {
        var lines = ["\(finding.package) › \(finding.target)"]
        lines.append("  path: " + finding.chain.map(\.label).joined(separator: " → "))
        if !finding.appleOnlyImports.isEmpty {
            lines.append("  imports: " + finding.appleOnlyImports.joined(separator: ", "))
        }
        let apis = FullFoundationAPI.allCases.compactMap { api -> String? in
            guard let symbols = finding.fullFoundationAPIs[api.rawValue], !symbols.isEmpty else { return nil }
            return "\(symbols.joined(separator: ", ")) (\(api.label))"
        }
        if !apis.isEmpty {
            lines.append("  uses: " + apis.joined(separator: "; "))
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
    static let allCasesInReportOrder: [Verdict] = [.likelyEasy, .needsFullFoundation, .appleOnly]

    func summaryLabel(count: Int) -> String {
        let one = count == 1
        return switch self {
        case .likelyEasy: one ? "looks easy to fix" : "look easy to fix"
        case .needsFullFoundation: one ? "uses full-Foundation APIs" : "use full-Foundation APIs"
        case .appleOnly: one ? "imports Apple-only frameworks" : "import Apple-only frameworks"
        }
    }

    var heading: String {
        switch self {
        case .likelyEasy: "Likely easy: no APIs beyond FoundationEssentials found"
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
