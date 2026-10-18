import SwiftSyntax

/// A method, property or initializer that exists only in the full Foundation, on a type that
/// FoundationEssentials has too, such as `String` or `FileManager`.
///
/// These are matched only where the name is used as a member (`.name`) or called (`name(...)`), and only
/// with the expected argument labels, so a variable named `range` or `URL.appending(path:)` doesn't count.
struct MemberAPI: Sendable {
    var api: FullFoundationAPI
    /// How the report shows it.
    var label: String
    /// Labels the first argument must have, `_` for an unlabeled one. When set, only calls count.
    var firstLabels: Set<String>?
    /// Labels that mean another API with the same name, such as `Calendar.range(of:in:for:)`.
    var excludedLabels: Set<String> = []

    /// Members found missing by building packages with FoundationEssentials from Swift 6.4.1, by name.
    static let members: [String: MemberAPI] = [
        "replacingOccurrences": MemberAPI(api: .corelibsOnly, label: "replacingOccurrences"),
        "trimmingCharacters": MemberAPI(api: .corelibsOnly, label: "trimmingCharacters"),
        // FoundationEssentials has `Data.range(of:options:in:)` and `Calendar.range(of:in:for:)`.
        "range": MemberAPI(api: .corelibsOnly, label: "range(of:)", firstLabels: ["of"], excludedLabels: ["in"]),
        "caseInsensitiveCompare": MemberAPI(api: .corelibsOnly, label: "caseInsensitiveCompare"),
        "localizedCaseInsensitiveCompare": MemberAPI(api: .corelibsOnly, label: "localizedCaseInsensitiveCompare"),
        "localizedCapitalized": MemberAPI(api: .formatting, label: "localizedCapitalized"),
        // FoundationEssentials has a fileprivate `addingPercentEncoding(forURLComponent:)`.
        "addingPercentEncoding": MemberAPI(
            api: .corelibsOnly, label: "addingPercentEncoding(withAllowedCharacters:)",
            firstLabels: ["withAllowedCharacters"]
        ),
        "removingPercentEncoding": MemberAPI(api: .corelibsOnly, label: "removingPercentEncoding"),
        "padding": MemberAPI(api: .corelibsOnly, label: "padding(toLength:)", firstLabels: ["toLength"]),
        // `URL.appending(path:)` and the like are in FoundationEssentials.
        "appending": MemberAPI(api: .corelibsOnly, label: "appending(_:)", firstLabels: ["_"]),
        "replacingCharacters": MemberAPI(api: .corelibsOnly, label: "replacingCharacters(in:with:)", firstLabels: ["in"]),
        "getLineStart": MemberAPI(api: .corelibsOnly, label: "getLineStart"),
        "rangeOfCharacter": MemberAPI(api: .corelibsOnly, label: "rangeOfCharacter(from:)", firstLabels: ["from"]),
        "precomposedStringWithCanonicalMapping": MemberAPI(api: .corelibsOnly, label: "precomposedStringWithCanonicalMapping"),
        "cString": MemberAPI(api: .corelibsOnly, label: "cString(using:)", firstLabels: ["using"]),
        "monthSymbols": MemberAPI(api: .formatting, label: "monthSymbols"),
        "weekdaySymbols": MemberAPI(api: .formatting, label: "weekdaySymbols"),
        "enumerator": MemberAPI(api: .corelibsOnly, label: "enumerator(at:)", firstLabels: ["at", "atPath"]),
        "fileSystemRepresentation": MemberAPI(
            api: .corelibsOnly, label: "fileSystemRepresentation(withPath:)", firstLabels: ["withPath"]
        ),
        "checkResourceIsReachable": MemberAPI(api: .corelibsOnly, label: "checkResourceIsReachable"),
    ]

    /// Initializers missing from FoundationEssentials, by type name.
    static let initializers: [String: [MemberAPI]] = [
        "String": [
            MemberAPI(api: .corelibsOnly, label: "String(format:)", firstLabels: ["format"]),
            // FoundationEssentials has only the variants with `encoding:` or `usedEncoding:`.
            MemberAPI(
                api: .corelibsOnly, label: "String(contentsOf:)", firstLabels: ["contentsOf", "contentsOfFile"],
                excludedLabels: ["encoding", "usedEncoding"]
            ),
            MemberAPI(api: .corelibsOnly, label: "String(utf8String:)", firstLabels: ["utf8String"]),
        ],
    ]

    /// Whether `token`, the name of this member, is used as `.name` or called as `name(...)`.
    func matches(memberName token: TokenSyntax) -> Bool {
        guard let reference = token.parent?.as(DeclReferenceExprSyntax.self) else { return false }
        var expression = ExprSyntax(reference)
        var isMember = false
        if let access = reference.parent?.as(MemberAccessExprSyntax.self), access.declName.id == reference.id {
            expression = ExprSyntax(access)
            isMember = true
        }
        let call = Self.call(of: expression)
        // A bare name that isn't called is usually a variable.
        guard isMember || call != nil else { return false }
        return matches(call)
    }

    /// Whether `token`, a type name, is called as an initializer with this one's labels.
    func matches(typeName token: TokenSyntax) -> Bool {
        guard let reference = token.parent?.as(DeclReferenceExprSyntax.self),
              let call = Self.call(of: ExprSyntax(reference))
        else { return false }
        return matches(call)
    }

    private func matches(_ call: FunctionCallExprSyntax?) -> Bool {
        let labels = call?.arguments.map { $0.label?.text ?? "_" } ?? []
        if let firstLabels {
            guard call != nil, let first = labels.first, firstLabels.contains(first) else { return false }
        }
        return excludedLabels.isDisjoint(with: labels)
    }

    /// The call whose callee is `expression`, if any.
    private static func call(of expression: ExprSyntax) -> FunctionCallExprSyntax? {
        guard let call = expression.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == expression.id else {
            return nil
        }
        return call
    }
}
