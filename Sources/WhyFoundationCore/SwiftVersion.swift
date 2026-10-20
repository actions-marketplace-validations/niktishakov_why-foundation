/// A Swift release, such as 6.4.1. FoundationEssentials comes with the toolchain, so what it has depends on it.
public struct SwiftVersion: Comparable, CustomStringConvertible, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// A development toolchain, such as `6.5-dev` built from main.
    public var isDevelopment: Bool

    public init(_ major: Int, _ minor: Int, _ patch: Int = 0, isDevelopment: Bool = false) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.isDevelopment = isDevelopment
    }

    /// Parses `6.4`, `6.4.1` or `6.5-dev`.
    public init?(_ text: some StringProtocol) {
        var text = Substring(text)
        let isDevelopment = text.hasSuffix("-dev")
        if isDevelopment {
            text = text.dropLast("-dev".count)
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (2...3).contains(parts.count), let major = parts[0], let minor = parts[1] else { return nil }
        let patch = parts.count == 3 ? parts[2] : 0
        guard let patch else { return nil }
        self.init(major, minor, patch, isDevelopment: isDevelopment)
    }

    /// The version in the output of `swift --version`, such as "Swift version 6.4.1 (swift-6.4.1-RELEASE)"
    /// or "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)".
    public init?(versionOutput: String) {
        guard let range = versionOutput.firstRange(of: "Swift version ") else { return nil }
        self.init(versionOutput[range.upperBound...].prefix { !$0.isWhitespace })
    }

    public var description: String {
        let number = patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
        return isDevelopment ? number + "-dev" : number
    }

    /// Compares the numbers only: a `6.5-dev` toolchain counts as 6.5.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) == (rhs.major, rhs.minor, rhs.patch)
    }
}
