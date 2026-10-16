import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Runs an external command and captures its output.
///
/// This uses `posix_spawn` and writes the output to temporary files instead of using Foundation's
/// `Process` with pipes: in a statically linked Linux build, `Process` can keep waiting for the pipe
/// after the child has exited.
enum Command {
    struct Result {
        var exitCode: Int32
        var output: Data
        var errorOutput: Data
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case spawnFailed(String, Int32)

        var description: String {
            switch self {
            case .spawnFailed(let command, let code):
                "Could not run `\(command)`: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Runs `arguments` through `/usr/bin/env`, so the first argument is looked up in `PATH`.
    static func run(_ arguments: [String]) throws -> Result {
        let directory = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let outputURL = directory.appendingPathComponent("why-foundation-\(id).out")
        let errorURL = directory.appendingPathComponent("why-foundation-\(id).err")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, outputURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, errorURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)

        let argv: [UnsafeMutablePointer<CChar>?] = (["/usr/bin/env"] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid = pid_t()
        let spawnResult = posix_spawn(&pid, "/usr/bin/env", &actions, nil, argv, envp)
        guard spawnResult == 0 else {
            throw Error.spawnFailed(arguments.joined(separator: " "), spawnResult)
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        // WIFEXITED / WEXITSTATUS, which aren't available as functions in Swift.
        let exitCode: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)

        return Result(
            exitCode: exitCode,
            output: (try? Data(contentsOf: outputURL)) ?? Data(),
            errorOutput: (try? Data(contentsOf: errorURL)) ?? Data()
        )
    }
}
