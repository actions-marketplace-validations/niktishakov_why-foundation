# why-foundation

[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fniktishakov%2Fwhy-foundation%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/niktishakov/why-foundation)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fniktishakov%2Fwhy-foundation%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/niktishakov/why-foundation)

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

The tool runs `swift package` under the hood, so it needs a Swift toolchain (6.1 or later) on the machine.

Download a prebuilt binary from the [latest release](https://github.com/niktishakov/why-foundation/releases/latest):

```bash
# macOS (Apple silicon and Intel)
curl -sL https://github.com/niktishakov/why-foundation/releases/latest/download/why-foundation-macos.tar.gz | tar xz
# Linux (x86_64 or aarch64)
curl -sL https://github.com/niktishakov/why-foundation/releases/latest/download/why-foundation-linux-$(uname -m).tar.gz | tar xz
```

Then move `why-foundation` somewhere on your `PATH`, for example `/usr/local/bin`.

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

Exit codes, for CI:

| Code | Meaning |
|---|---|
| 0 | Nothing pulls in the full Foundation. |
| 1 | Something pulls in the full Foundation. |
| 2 | The analysis didn't run, for example because SwiftPM couldn't load the package graph. Only SwiftPM's `error:` lines are printed. |
| 64 | Wrong command-line arguments. |

### In CI

With the GitHub Action, after the step that sets up Swift:

```yaml
- uses: niktishakov/why-foundation@v0
  with:
    product: MyLibrary
```

The job fails when anything pulls in the full Foundation, or when the package can't be analyzed (exit code 2, with an error annotation). Inputs: `version` (default `latest`), `package-path`, `product`, `platform` (`android` or `linux`), `include-tests` and `verbose`. The action downloads a prebuilt binary, so it takes seconds, and it runs on Linux and macOS runners.

Or call the binary yourself:

```yaml
- name: Check that the full Foundation isn't pulled in
  run: |
    curl -sfL https://github.com/niktishakov/why-foundation/releases/download/0.1.2/why-foundation-linux-$(uname -m).tar.gz | tar xz -C "$RUNNER_TEMP"
    "$RUNNER_TEMP/why-foundation" --product MyLibrary
```

This downloads a prebuilt binary, so the check takes seconds. The official `swift` Docker images don't include `curl`; in such a container, install it first with `apt-get update && apt-get install -y curl`. Pass `--platform linux` to check a Linux build instead of an Android one.

## What it checks

For every target reachable from your entry points:

- `import Foundation`, `FoundationNetworking`, `FoundationXML` and `FoundationInternationalization` that stay active on the platform. `#if canImport(FoundationEssentials)` fallbacks, `#if os(...)`, package traits and `swiftSettings` defines are all taken into account.
- Resources declared in `Package.swift`. SwiftPM generates a `Bundle.module` accessor for them that imports Foundation, even if your code never does ([swift-package-manager#9792](https://github.com/swiftlang/swift-package-manager/issues/9792)).
- Dependency conditions: `.when(platforms:)` and `.when(traits:)`.

Each finding gets a verdict:

| Verdict | Meaning |
|---|---|
| Likely easy | No APIs beyond `FoundationEssentials` found. Switching the import is probably enough. |
| Likely easy, plus a one-line fix | The same, but the code also uses what `import Foundation` re-exports: C library calls such as `isatty` or `pthread_mutex_lock`, `DispatchQueue`, or names written as `Foundation.X`. The report shows the fix, such as ``add `import Dispatch` ``. |
| Uses full-Foundation APIs | Uses `URLSession`, legacy formatters, `NSLock`, `Bundle`, `String` methods such as `replacingOccurrences` or similar. Needs real work, or isn't worth changing. |
| Apple-only | Imports `UIKit`, `SwiftUI` or another Apple framework, so it doesn't build for Android anyway. |

The [Swift Ecosystem Steering Group recommends](https://forums.swift.org/t/the-adoption-of-import-foundationessentials-throughout-the-package-ecosystem/84112/16) switching to `FoundationEssentials` where a package only uses APIs available there. The two "likely easy" groups are where that applies.

## Accuracy

The verdicts were checked against real Android builds made with the Swift SDK for Android 6.4.1: `llvm-readelf` on the built library showed `libFoundation.so` exactly when `why-foundation` reported a finding.

Known limits:

- `Package.swift` is evaluated on the machine where you run the tool, as it is when you build. A manifest that adds resources under `#if canImport(Darwin)` still adds them when you cross-compile for Android from a Mac, and the report shows that.
- For Xcode projects, only the Swift package dependencies are analyzed, not the app's own sources. `.xcworkspace` isn't supported yet.
- Full-Foundation APIs are detected by name. Names that the target or its dependencies declare, such as a type of your own called `Timer`, are not counted. An API missing from the list is not reported. Treat "likely easy" as a hint: the reliable check is building the target on Linux with `FoundationEssentials`.
- Binary targets can't be inspected and are listed separately.

## License

Apache License 2.0. See [LICENSE](LICENSE).
