import SwiftSyntax

/// A change, besides switching the import, that a file needs once it imports FoundationEssentials instead of
/// Foundation. `import Foundation` re-exports the C library and Dispatch, and FoundationEssentials doesn't.
public struct OneLineFix: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Comparable, Sendable {
        /// C library functions, types and constants, such as `pthread_mutex_lock` or `stdout`.
        case libc
        /// `DispatchQueue` and the rest of Dispatch.
        case dispatch
        /// Names written as `Foundation.X`.
        case qualifier

        public static func < (lhs: Self, rhs: Self) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }

        /// What to do, for `platform`.
        func suggestion(for platform: TargetPlatform) -> String {
            switch self {
            case .libc:
                switch platform {
                case .android: "add `import Android`"
                case .linux: "add `import Glibc` (`import Musl` with the static Linux SDK)"
                }
            case .dispatch: "add `import Dispatch`"
            case .qualifier: "drop the `Foundation.` qualifier"
            }
        }

        /// Modules whose import already provides what the file uses.
        var coveringModules: Set<String> {
            switch self {
            case .libc: ["Glibc", "Musl", "Android", "Bionic", "Darwin", "WASILibc", "ucrt", "CRT", "WinSDK"]
            case .dispatch: ["Dispatch"]
            case .qualifier: []
            }
        }
    }

    public var kind: Kind
    /// The change to make, such as "add `import Dispatch`".
    public var suggestion: String
    /// What needs it, such as `DispatchQueue`.
    public var symbols: [String]
    /// The files that need it, relative to the package directory.
    public var files: [String]

    /// C library names that real packages used through `import Foundation`, found by building them with
    /// FoundationEssentials. `pthread_` and `PTHREAD_` names count too.
    static let libcNames: Set<String> = [
        // Glibc written out, as in `Glibc.exit(1)`.
        "Glibc",
        // stdio, stdlib, string
        "FILE", "stdin", "stdout", "stderr", "fopen", "fclose", "fread", "fwrite", "fputs", "fflush", "fileno",
        "feof", "ferror", "fseek", "fseeko", "ftello", "setvbuf", "_IOFBF", "SEEK_SET", "SEEK_CUR", "SEEK_END",
        "fopencookie", "cookie_io_functions_t", "exit", "_exit", "free", "strdup", "strlen", "strcmp", "strerror",
        "memcmp", "memmove", "atof", "drand48", "setenv", "unsetenv", "UINT16_MAX", "DBL_DECIMAL_DIG",
        // math
        "pow", "sqrt", "ceil", "floor", "round", "modf", "atan2", "sin", "cos",
        // errno and signals
        "errno", "EAGAIN", "EBUSY", "EDEADLK", "ENOENT", "SIGINT", "SIGSTOP", "SIGTERM", "SIGHUP", "SIGKILL",
        "SIGWINCH", "SIG_DFL", "SIG_SETMASK", "NSIG", "signal", "sigaction", "sigemptyset", "sigprocmask", "sigset_t",
        // files and processes
        "stat", "lstat", "S_IFDIR", "S_IFMT", "S_IFLNK", "S_IFREG", "off_t", "mode_t", "opendir", "readdir",
        "closedir", "chdir", "getcwd", "ftruncate", "lchmod", "lutimes", "fpathconf", "_PC_VDISABLE", "glob_t",
        "globfree", "GLOB_BRACE", "GLOB_MARK", "GLOB_TILDE", "read", "STDIN_FILENO", "STDOUT_FILENO", "getpid",
        "pid_t", "execve", "dlopen", "dlsym", "dlerror", "RTLD_LAZY",
        // terminals
        "isatty", "ioctl", "tcgetattr", "tcsetattr", "termios", "winsize", "TIOCGWINSZ", "TIOCSWINSZ",
        "TCSAFLUSH", "ECHO", "ICANON", "VDISCARD", "VEOF", "VEOL", "VEOL2", "VERASE", "VINTR", "VKILL", "VLNEXT",
        "VQUIT", "VREPRINT", "VSTART", "VSTOP", "VSUSP", "VSWTC", "VWERASE", "forkpty",
        // sockets
        "socket", "bind", "listen", "accept", "send", "setsockopt", "getpeername", "getsockname", "getnameinfo",
        "inet_pton", "ntohs", "sockaddr", "sockaddr_in", "sockaddr_in6", "sa_family_t", "socklen_t", "in_addr",
        "in_addr_t", "in_port_t", "in6addr_any", "AF_INET", "AF_INET6", "SOCK_STREAM", "SOL_SOCKET", "SOMAXCONN",
        "SO_REUSEADDR", "MSG_NOSIGNAL", "NI_MAXHOST", "NI_NUMERICHOST",
        // time
        "time_t", "timespec", "timeval", "tm", "gmtime", "timegm",
    ]

    /// The kind of fix a name could need, before its context is checked.
    static func kind(of name: String) -> Kind? {
        if name == "Foundation" {
            return .qualifier
        }
        if libcNames.contains(name) || name.hasPrefix("pthread_") || name.hasPrefix("PTHREAD_") {
            return .libc
        }
        if name == "dispatchMain" || name == "dispatchPrecondition" {
            return .dispatch
        }
        if name.hasPrefix("Dispatch"), let next = name.dropFirst("Dispatch".count).first, next.isUppercase {
            return .dispatch
        }
        return nil
    }

    /// The fix `token` needs and the name the report shows for it.
    ///
    /// Only free names count: `x.stat` or `.round` is a member of something else.
    static func match(_ token: TokenSyntax) -> (kind: Kind, name: String)? {
        guard let kind = kind(of: token.text), !isInCondition(token) else { return nil }
        if let reference = token.parent?.as(DeclReferenceExprSyntax.self) {
            if let access = reference.parent?.as(MemberAccessExprSyntax.self), access.declName.id == reference.id {
                return nil
            }
        } else if token.parent?.is(IdentifierTypeSyntax.self) != true {
            return nil
        }
        guard kind == .qualifier else { return (kind, token.text) }
        // `Foundation.JSONDecoder`, as an expression or as a type.
        guard let period = token.nextToken(viewMode: .sourceAccurate), period.tokenKind == .period,
              let member = period.nextToken(viewMode: .sourceAccurate)
        else { return nil }
        return (kind, "Foundation.\(member.text)")
    }

    /// Whether `token` is part of an `#if` condition, as `Glibc` is in `#if canImport(Glibc)`.
    private static func isInCondition(_ token: TokenSyntax) -> Bool {
        var node = token.parent
        while let current = node {
            if let clause = current.as(IfConfigClauseSyntax.self), let condition = clause.condition,
               condition.position <= token.position, token.position < condition.endPosition {
                return true
            }
            node = current.parent
        }
        return false
    }
}
