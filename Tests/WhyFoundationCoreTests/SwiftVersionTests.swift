import Testing
@testable import WhyFoundationCore

@Suite struct SwiftVersionTests {
    @Test func versionOutput() {
        #expect(SwiftVersion(versionOutput: "Swift version 6.4.1 (swift-6.4.1-RELEASE)\nTarget: aarch64-unknown-linux-gnu\n") == SwiftVersion(6, 4, 1))
        #expect(SwiftVersion(versionOutput: "swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)\nTarget: arm64-apple-macosx27.0.0\n") == SwiftVersion(6, 4))
        let main = SwiftVersion(versionOutput: "Swift version 6.5-dev (LLVM 3f1c1a7e, Swift 0b6c5d1a)\n")
        #expect(main == SwiftVersion(6, 5))
        #expect(main?.isDevelopment == true)
        #expect(main?.description == "6.5-dev")
        #expect(SwiftVersion(versionOutput: "bash: swift: command not found") == nil)
    }

    @Test func option() {
        #expect(SwiftVersion("6.4") == SwiftVersion(6, 4, 0))
        #expect(SwiftVersion("6.4.1")?.description == "6.4.1")
        #expect(SwiftVersion("6") == nil)
        #expect(SwiftVersion("latest") == nil)
        #expect(SwiftVersion(6, 4, 1) < SwiftVersion(6, 5))
    }

    @Test func toolchainOnThisMachine() {
        #expect(GraphLoader.swiftVersion() != nil)
    }
}
