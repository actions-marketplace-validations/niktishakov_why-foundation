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
        for decl in collector.imports where regions.isActive(decl) == .active {
            guard let name = decl.path.first?.name.text else { continue }
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
        for token in collector.symbolTokens where regions.isActive(token) == .active {
            if let (api, name) = FullFoundationAPI.match(token) {
                result.fullFoundationAPIs[api, default: []].insert(name)
            }
        }
        return result
    }
}

private final class Collector: SyntaxVisitor {
    var imports: [ImportDeclSyntax] = []
    var symbolTokens: [TokenSyntax] = []

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        imports.append(node)
        return .skipChildren
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        if case .identifier = token.tokenKind, FullFoundationAPI.isCandidate(token.text) {
            symbolTokens.append(token)
        }
        return .skipChildren
    }
}
