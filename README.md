# why-foundation

Find out which dependencies pull the full Foundation into your Android or Linux build.

On Apple platforms Foundation is part of the OS. On Android and Linux it ships with your app, and `import Foundation` brings in ICU, a large library for dates, numbers and languages. With the Swift SDK for Android that is about 48 MB per architecture. `import FoundationEssentials` avoids it, but only if nothing in the dependency graph imports Foundation.

`why-foundation` shows every target in your graph that pulls in Foundation, the dependency path that leads there, and how hard it is to fix.

```
$ why-foundation
✗ 7 targets pull the full Foundation (and ICU) into the android build.
  3 look easy to fix · 4 use full-Foundation APIs

── Likely easy: no APIs beyond FoundationEssentials found ──

swift-protobuf › SwiftProtobuf
  path: Shared → SwiftProtobuf (swift-protobuf)
  resources in Package.swift  (SwiftPM's generated resource accessor imports Foundation)
  Sources/SwiftProtobuf/BinaryDelimited.swift:16  import Foundation

…

── Use APIs that need the full Foundation ──

swift-dependencies › Dependencies
  path: Shared → Dependencies (swift-dependencies)
  uses: URLProtocol, URLRequest, URLSession, URLSessionConfiguration (FoundationNetworking); NSRecursiveLock, NotificationCenter (not in FoundationEssentials)
  Sources/Dependencies/DependencyValues.swift:1  import Foundation
  Sources/Dependencies/DependencyValues/Calendar.swift:2  import Foundation
  Sources/Dependencies/DependencyValues/Date.swift:2  import Foundation
  … and 9 more (--verbose)

…
```

## Install

Requires Swift 6.1 or later on macOS or Linux.

With [Mint](https://github.com/yonaskolb/Mint):

```bash
mint install niktishakov/why-foundation
```

Or from source:

```bash
git clone https://github.com/niktishakov/why-foundation
cd why-foundation
swift package experimental-install
```

This puts `why-foundation` in `~/.swiftpm/bin`. You can also run it from the clone with `swift run why-foundation`.

## Usage

Run it in a package directory, or point it at a package or an Xcode project:

```bash
why-foundation
why-foundation --package-path path/to/MyApp.xcodeproj
why-foundation --product MySharedLibrary
why-foundation --platform linux
why-foundation --json
```

| Option | Meaning |
|---|---|
| `-p, --package-path` | A Swift package, an `.xcodeproj`, or a directory with one of them. Default: the current directory. |
| `--platform` | `android` (default) or `linux`. Decides how `#if` blocks and platform conditions are evaluated. |
| `--product` | Analyze one product of the root package instead of all its targets. |
| `--include-tests` | Also analyze test targets. |
| `--json` | Machine-readable output. |
| `--verbose` | List every import instead of the first few per target. |

The exit code is 1 when anything pulls in Foundation, so you can use it in CI.

### In CI

To fail a GitHub Actions job when a dependency starts pulling in Foundation:

```yaml
- name: Check that the full Foundation isn't pulled in
  run: |
    git clone --depth 1 --branch 0.1.0 https://github.com/niktishakov/why-foundation /tmp/why-foundation
    swift run --package-path /tmp/why-foundation -c release why-foundation --package-path . --product MyLibrary
```

Pass `--platform linux` to check a Linux build instead of an Android one.

## What it checks

For every target reachable from your entry points:

- `import Foundation`, `FoundationNetworking`, `FoundationXML` and `FoundationInternationalization` that stay active on the platform. `#if canImport(FoundationEssentials)` fallbacks, `#if os(...)`, package traits and `swiftSettings` defines are all taken into account.
- Resources declared in `Package.swift`. SwiftPM generates a `Bundle.module` accessor for them that imports Foundation, even if your code never does ([swift-package-manager#9792](https://github.com/swiftlang/swift-package-manager/issues/9792)).
- Dependency conditions: `.when(platforms:)` and `.when(traits:)`.

Each finding gets a verdict:

| Verdict | Meaning |
|---|---|
| Likely easy | No APIs beyond `FoundationEssentials` found. Switching the import is probably enough. |
| Uses full-Foundation APIs | Uses `URLSession`, legacy formatters, `NSLock`, `Bundle` or similar. Needs real work, or isn't worth changing. |
| Apple-only | Imports `UIKit`, `SwiftUI` or another Apple framework, so it doesn't build for Android anyway. |

The [Swift Ecosystem Steering Group recommends](https://forums.swift.org/t/the-adoption-of-import-foundationessentials-throughout-the-package-ecosystem/84112/16) switching to `FoundationEssentials` where a package only uses APIs available there. The "likely easy" group is where that applies.

## Accuracy

The verdicts were checked against real Android builds made with the Swift SDK for Android 6.4.1: `llvm-readelf` on the built library showed `libFoundation.so` exactly when `why-foundation` reported a finding.

Known limits:

- `Package.swift` is evaluated on the machine where you run the tool, as it is when you build. A manifest that adds resources under `#if canImport(Darwin)` still adds them when you cross-compile for Android from a Mac, and the report shows that.
- For Xcode projects, only the Swift package dependencies are analyzed, not the app's own sources. `.xcworkspace` isn't supported yet.
- Full-Foundation APIs are detected by name. A type of your own called `Bundle` or `Timer` is reported too, and an API missing from the list is not. Treat "likely easy" as a hint: the reliable check is building the target on Linux with `FoundationEssentials`.
- Binary targets can't be inspected and are listed separately.

## License

Apache License 2.0. See [LICENSE](LICENSE).
