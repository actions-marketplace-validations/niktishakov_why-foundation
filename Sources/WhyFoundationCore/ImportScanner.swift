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
    /// Legacy formatters and `NSRegularExpression` need FoundationInternationalization and ICU.
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
        "NotificationCenter": .corelibsOnly, "Timer": .corelibsOnly, "RunLoop": .corelibsOnly,
        "OperationQueue": .corelibsOnly, "Thread": .corelibsOnly, "NSLock": .corelibsOnly,
        "NSRecursiveLock": .corelibsOnly, "NSCondition": .corelibsOnly, "Scanner": .corelibsOnly,
        "NSString": .corelibsOnly, "NSNumber": .corelibsOnly, "NSDictionary": .corelibsOnly,
        "NSArray": .corelibsOnly, "NSObject": .corelibsOnly, "NSError": .corelibsOnly,
        "UserDefaults": .corelibsOnly, "NSCache": .corelibsOnly,
    ]

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
            if let api = FullFoundationAPI.symbols[token.text] {
                result.fullFoundationAPIs[api, default: []].insert(token.text)
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
        if case .identifier = token.tokenKind, FullFoundationAPI.symbols[token.text] != nil {
            symbolTokens.append(token)
        }
        return .skipChildren
    }
}
