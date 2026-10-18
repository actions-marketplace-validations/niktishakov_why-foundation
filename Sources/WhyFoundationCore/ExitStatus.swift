/// The exit codes of `why-foundation`.
public enum ExitStatus: Int32, Sendable {
    /// Nothing in the build pulls in the full Foundation.
    case clean = 0
    /// At least one target pulls in the full Foundation.
    case foundationFound = 1
    /// The analysis didn't run, for example because SwiftPM couldn't load the package graph.
    case failure = 2

    public init(report: Report) {
        self = report.findings.isEmpty ? .clean : .foundationFound
    }
}
