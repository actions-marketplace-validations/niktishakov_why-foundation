#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public func now() -> Date { Date() }
