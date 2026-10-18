import SwiftIfConfig
import SwiftParser
import SwiftSyntax

/// Modules that bring the full Foundation, and with it ICU, into a non-Darwin build.
public enum HeavyModule: String, CaseIterable, Codable, Sendable {
    case foundation = "Foundation"
    case foundationInternationalization = "FoundationInternationalization"
    case foundationNetworking = "FoundationNetworking"
    case foundationXML = "FoundationXML"
}

/// An import of a heavy module that stays active for the analyzed platform.
public struct HeavyImport: Codable, Equatable, Sendable {
    public var module: HeavyModule
    public var line: Int
    /// `@_exported import`: every client of the module sees Foundation too.
    public var isExported: Bool
}

/// Why code that uses an API can't switch to `FoundationEssentials`.
public enum FullFoundationAPI: String, Codable, CaseIterable, Comparable, Sendable {
    /// `URLSession` and friends live in FoundationNetworking, which needs the full Foundation.
    case networking
    /// Legacy formatters, `NSRegularExpression` and FoundationInternationalization types such as `Measurement`
    /// need ICU.
    case formatting
    /// Types that exist only in swift-corelibs-foundation.
    case corelibsOnly

    static let symbols: [String: FullFoundationAPI] = [
        "URLSession": .networking, "URLSessionConfiguration": .networking, "URLSessionTask": .networking,
        "URLSessionDataTask": .networking, "URLSessionWebSocketTask": .networking, "URLRequest": .networking,
        "URLResponse": .networking, "HTTPURLResponse": .networking, "URLProtocol": .networking,
        "URLCache": .networking, "HTTPCookie": .networking, "HTTPCookieStorage": .networking,
        "DateFormatter": .formatting, "NumberFormatter": .formatting, "ISO8601DateFormatter": .corelibsOnly,
        "DateComponentsFormatter": .formatting, "DateIntervalFormatter": .formatting,
        "RelativeDateTimeFormatter": .formatting, "MeasurementFormatter": .formatting,
        "ByteCountFormatter": .formatting, "ListFormatter": .formatting,
        "PersonNameComponentsFormatter": .formatting, "NSRegularExpression": .formatting,
        "JSONSerialization": .corelibsOnly, "PropertyListSerialization": .corelibsOnly, "Bundle": .corelibsOnly,
        "Timer": .corelibsOnly, "RunLoop": .corelibsOnly,
        "OperationQueue": .corelibsOnly, "Thread": .corelibsOnly, "NSLock": .corelibsOnly,
        "NSRecursiveLock": .corelibsOnly, "NSCondition": .corelibsOnly, "Scanner": .corelibsOnly,
        "NSString": .corelibsOnly, "NSNumber": .corelibsOnly, "NSDictionary": .corelibsOnly,
        "NSArray": .corelibsOnly, "NSObject": .corelibsOnly, "NSError": .corelibsOnly,
        "UserDefaults": .corelibsOnly, "NSCache": .corelibsOnly,
        "IndexSet": .corelibsOnly, "NSRange": .corelibsOnly, "NSMakeRange": .corelibsOnly,
        "AffineTransform": .corelibsOnly, "PersonNameComponents": .corelibsOnly,
        "FileHandle": .corelibsOnly, "Process": .corelibsOnly, "Pipe": .corelibsOnly,
        "InputStream": .corelibsOnly, "OutputStream": .corelibsOnly, "Host": .corelibsOnly,
        "NSCoder": .corelibsOnly, "NSKeyedArchiver": .corelibsOnly, "NSKeyedUnarchiver": .corelibsOnly,
        "NSAttributedString": .corelibsOnly, "NSMutableString": .corelibsOnly, "NSMutableArray": .corelibsOnly,
        "NSMutableDictionary": .corelibsOnly, "NSSet": .corelibsOnly, "NSURL": .corelibsOnly, "NSData": .corelibsOnly,
        "NSDate": .corelibsOnly, "NSValue": .corelibsOnly, "NSNull": .corelibsOnly, "NSDecimalNumber": .corelibsOnly,
        "NSPredicate": .corelibsOnly, "NSSortDescriptor": .corelibsOnly,
        // On non-Apple platforms, `Error.localizedDescription` exists only in swift-corelibs-foundation.
        "localizedDescription": .corelibsOnly,
        "Measurement": .formatting, "Dimension": .formatting, "UnitLength": .formatting, "UnitMass": .formatting,
        "UnitDuration": .formatting, "UnitTemperature": .formatting, "UnitSpeed": .formatting,
        "UnitInformationStorage": .formatting, "SortDescriptor": .formatting,
        // Found missing by building packages with FoundationEssentials from Swift 6.4.1.
        "URLError": .networking, "URLSessionDelegate": .networking, "URLSessionTaskDelegate": .networking,
        "URLSessionDataDelegate": .networking, "URLSessionDownloadDelegate": .networking,
        "URLSessionDownloadTask": .networking, "URLSessionTaskMetrics": .networking, "URLCredential": .networking,
        "URLAuthenticationChallenge": .networking, "URLProtectionSpace": .networking,
        "CachedURLResponse": .networking,
        "Formatter": .formatting, "FloatingPointFormatStyle": .formatting, "StringTransform": .formatting,
        "NSTextCheckingResult": .formatting,
        "CharacterSet": .corelibsOnly, "ObjCBool": .corelibsOnly, "Notification": .corelibsOnly,
        "Progress": .corelibsOnly, "CGFloat": .corelibsOnly, "Operation": .corelibsOnly,
        "BlockOperation": .corelibsOnly, "QualityOfService": .corelibsOnly, "URLResourceValues": .corelibsOnly,
        "DirectoryEnumerator": .corelibsOnly, "XMLParser": .corelibsOnly, "XMLParserDelegate": .corelibsOnly,
    ]

    /// The API a name stands for when it isn't in `symbols`: Objective-C style `NS` names and
    /// CoreFoundation's `CF` names, none of which FoundationEssentials has.
    static func prefixed(_ name: String) -> FullFoundationAPI? {
        for prefix in ["NS", "CF", "kCF"] where name.hasPrefix(prefix) {
            if let next = name.dropFirst(prefix.count).first, next.isUppercase {
                return .corelibsOnly
            }
        }
        return nil
    }

    /// Whether a token with this text may be a full-Foundation API, before its context is checked.
    static func isCandidate(_ name: String) -> Bool {
        symbols[name] != nil || MemberAPI.members[name] != nil || MemberAPI.initializers[name] != nil
            || prefixed(name) != nil
    }

    /// Whether `symbol`, as the report shows it, is a name that `declaredNames` contains, such as a type of
    /// the package's own called `Timer`.
    static func isShadowed(_ symbol: String, by declaredNames: Set<String>) -> Bool {
        // Error types often declare a `localizedDescription` of their own, and the code still calls it on
        // `any Error`.
        guard symbol != "localizedDescription" else { return false }
        let name = String(symbol.prefix { $0 != "(" })
        // An API matched by its argument labels is shadowed only by a function with the same first label:
        // a property named `range` doesn't hide `range(of:)`.
        let labelled = MemberAPI.members[name].map { [$0] } ?? MemberAPI.initializers[name] ?? []
        if let api = labelled.first(where: { $0.label == symbol }), let firstLabels = api.firstLabels {
            let function = MemberAPI.initializers[name] == nil ? name : "init"
            return firstLabels.contains { declaredNames.contains("\(function)(\($0):)") }
        }
        return declaredNames.contains(name)
    }

    /// The API `token` refers to and the name the report shows for it.
    static func match(_ token: TokenSyntax) -> (api: FullFoundationAPI, name: String)? {
        let name = token.text
        if let api = symbols[name] {
            return (api, name)
        }
        if let member = MemberAPI.members[name] {
            return member.matches(memberName: token) ? (member.api, member.label) : nil
        }
        if let initializers = MemberAPI.initializers[name] {
            return initializers.first { $0.matches(typeName: token) }.map { ($0.api, $0.label) }
        }
        return prefixed(name).map { ($0, name) }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Apple frameworks with no Android or Linux counterpart. An active import means the target
/// doesn't build for Android at all.
enum AppleOnlyModule {
    static let names: Set<String> = [
        "UIKit", "AppKit", "SwiftUI", "Combine", "WatchKit", "StoreKit", "AVFoundation", "AVKit",
        "CoreData", "CoreGraphics", "CoreImage", "CoreLocation", "CoreML", "CoreMotion", "CoreBluetooth",
        "CoreText", "CoreTelephony", "Photos", "PhotosUI", "WebKit", "SafariServices", "MapKit",
        "UserNotifications", "Security", "LocalAuthentication", "AuthenticationServices", "CryptoKit",
        "Network", "OSLog", "os", "ObjectiveC", "Darwin", "Accelerate", "Metal", "QuartzCore", "ARKit",
        "SceneKit", "SpriteKit", "GameKit", "HealthKit", "CloudKit", "Contacts", "ContactsUI", "EventKit",
        "MessageUI", "AdSupport", "AppTrackingTransparency", "SystemConfiguration",
        "MultipeerConnectivity", "PassKit", "QuickLook", "BackgroundTasks", "WidgetKit", "ActivityKit",
        "AppIntents", "Intents", "IntentsUI", "Vision", "VisionKit", "Speech", "NaturalLanguage",
        "GameController", "MetricKit", "DeviceCheck", "LinkPresentation", "Social", "iAd",
    ]
}

/// What one source file means for the analyzed platform.
struct FileScan: Equatable {
    var heavyImports: [HeavyImport] = []
    /// Apple-only modules imported in active code, in source order.
    var appleOnlyImports: [String] = []
    /// Full-Foundation APIs referenced in active code.
    var fullFoundationAPIs: [FullFoundationAPI: Set<String>] = [:]
    /// Types, functions, properties and enum cases the file declares in active code. Functions are also
    /// listed as `name(firstLabel:)`.
    var declaredNames: Set<String> = []
    /// Parameters and local variables: visible only in this file.
    var localNames: Set<String> = []
    /// Names that need another change once the file imports FoundationEssentials instead of Foundation.
    /// Empty unless the file imports Foundation.
    var oneLineFixes: [OneLineFix.Kind: Set<String>] = [:]
}

enum ImportScanner {
    /// Returns the heavy imports in `source` that are active under `configuration`.
    static func heavyImports(in source: String, configuration: some BuildConfiguration) -> [HeavyImport] {
        scan(source, configuration: configuration).heavyImports
    }

    static func scan(_ source: String, configuration: some BuildConfiguration) -> FileScan {
        let tree = Parser.parse(source: source)
        let regions = tree.configuredRegions(in: configuration)
        let converter = SourceLocationConverter(fileName: "", tree: tree)
        let collector = Collector(viewMode: .sourceAccurate)
        collector.walk(tree)

        var result = FileScan()
        var importedModules: Set<String> = []
        for decl in collector.imports where regions.isActive(decl) == .active {
            guard let name = decl.path.first?.name.text else { continue }
            importedModules.insert(name)
            if let module = HeavyModule(rawValue: name) {
                let isExported = decl.attributes.contains { element in
                    element.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "_exported"
                }
                let line = decl.startLocation(converter: converter, afterLeadingTrivia: true).line
                result.heavyImports.append(HeavyImport(module: module, line: line, isExported: isExported))
            } else if AppleOnlyModule.names.contains(name), !result.appleOnlyImports.contains(name) {
                result.appleOnlyImports.append(name)
            }
        }
        let importsFoundation = result.heavyImports.contains { $0.module == .foundation }
        for token in collector.symbolTokens where regions.isActive(token) == .active {
            if let (api, name) = FullFoundationAPI.match(token) {
                result.fullFoundationAPIs[api, default: []].insert(name)
            } else if importsFoundation, let (kind, name) = OneLineFix.match(token),
                      kind.coveringModules.isDisjoint(with: importedModules) {
                result.oneLineFixes[kind, default: []].insert(name)
            }
        }
        for name in collector.declaredNames where regions.isActive(name) == .active {
            result.declaredNames.insert(name.text.filter { $0 != "`" })
        }
        for name in collector.localNames where regions.isActive(name) == .active {
            result.localNames.insert(name.text.filter { $0 != "`" })
        }
        for function in collector.declaredFunctions where regions.isActive(function.token) == .active {
            result.declaredNames.insert(function.key)
        }
        return result
    }
}

private final class Collector: SyntaxVisitor {
    var imports: [ImportDeclSyntax] = []
    var symbolTokens: [TokenSyntax] = []
    var declaredNames: [TokenSyntax] = []
    /// Declared functions, as `name(firstLabel:)`, with the token that decides whether they are active.
    var declaredFunctions: [(key: String, token: TokenSyntax)] = []
    var localNames: [TokenSyntax] = []

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        imports.append(node)
        return .skipChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { declare(node.name) }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { declare(node.name) }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { declare(node.name) }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { declare(node.name) }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { declare(node.name) }
    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind { declare(node.name) }
    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind { declare(node.name) }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        declareFunction(node.name.text, node.signature, at: node.name)
        return declare(node.name)
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        declareFunction("init", node.signature, at: node.initKeyword)
        return .visitChildren
    }
    override func visit(_ node: EnumCaseElementSyntax) -> SyntaxVisitorContinueKind { declare(node.name) }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isLocal = node.ancestorOrSelf { $0.is(CodeBlockSyntax.self) || $0.is(ClosureExprSyntax.self) } != nil
        for binding in node.bindings {
            if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                if isLocal {
                    localNames.append(pattern.identifier)
                } else {
                    declaredNames.append(pattern.identifier)
                }
            }
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionParameterSyntax) -> SyntaxVisitorContinueKind {
        localNames.append(node.secondName ?? node.firstName)
        return .visitChildren
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        localNames.append(node.secondName ?? node.firstName)
        return .visitChildren
    }

    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        localNames.append(node.name)
        return .visitChildren
    }

    private func declare(_ name: TokenSyntax) -> SyntaxVisitorContinueKind {
        declaredNames.append(name)
        return .visitChildren
    }

    private func declareFunction(_ name: String, _ signature: FunctionSignatureSyntax, at token: TokenSyntax) {
        let label = signature.parameterClause.parameters.first?.firstName.text ?? "_"
        declaredFunctions.append(("\(name)(\(label):)", token))
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        if case .identifier = token.tokenKind,
           FullFoundationAPI.isCandidate(token.text) || OneLineFix.kind(of: token.text) != nil {
            symbolTokens.append(token)
        }
        return .skipChildren
    }
}
