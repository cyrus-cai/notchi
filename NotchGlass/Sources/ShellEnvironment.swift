import Foundation

/// The user's **real** shell environment, for the agent CLIs Notch spawns
/// (`claude`, `codex`, `grok`, `cmd`).
///
/// Notch is a GUI app, so it inherits **launchd's** environment — `PATH` is
/// `/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` and nothing else. Everything the
/// user's shell config builds is missing, which breaks CLI support twice over:
///
///  1. **Finding the binary.** A CLI installed by a node version manager (nvm /
///     fnm / volta / hermes) lives in that manager's bin dir, which is on no fixed
///     list and not in launchd's PATH.
///  2. **Running it.** Most of these CLIs are `#!/usr/bin/env node` scripts, so the
///     shebang re-runs a PATH lookup at exec time — and under a version manager the
///     only `node` on the machine sits in that same bin dir. Without it the spawn
///     dies with `env: node: No such file or directory`, which reads to the user as
///     "not installed" even though the CLI works fine in their terminal.
///
/// The shell is asked with **`-ilc` — interactive *and* login**, and that is the
/// whole trick. zsh sources `.zprofile` for login shells but `.zshrc` only for
/// *interactive* ones, and `.zshrc` is where `export PATH=…` actually lands for
/// most people. A plain `-lc` probe (what this code used to do) reports a PATH the
/// user has never seen, missing exactly the dir the CLI is installed in.
///
/// This is the child-process twin of `ProxyConfig`, which solves the same
/// "launchd's environment isn't the user's" problem for proxy variables.
enum ShellEnvironment {

    // MARK: - The shell's PATH

    private static let lock = NSLock()
    /// Double-optional cache: `nil` = never probed, `.some(nil)` = probed, no answer.
    private nonisolated(unsafe) static var cachedPATH: String??

    /// The user's shell `PATH`, split into directories. Probed once per process
    /// (a login+interactive shell costs ~100-300ms), so warm it off-main via
    /// `warmUp()` — the CLI services already do at launch.
    static var pathDirs: [String] {
        lock.lock()
        if let cached = cachedPATH {
            lock.unlock()
            return (cached ?? "").split(separator: ":").map(String.init)
        }
        lock.unlock()
        let probed = probePATH()
        lock.lock(); cachedPATH = .some(probed); lock.unlock()
        return (probed ?? "").split(separator: ":").map(String.init)
    }

    /// Probe the PATH off the main thread.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async { _ = pathDirs }
    }

    /// An interactive rc file may print banners, so the value is fenced in markers
    /// rather than read as the whole of stdout, and a watchdog bounds a shell that
    /// decides to block (this is reachable from a SwiftUI render).
    private static func probePATH() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let begin = "__NOTCH_PATH__", end = "__NOTCH_END__"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf '\\n\(begin)%s\(end)\\n' \"$PATH\""]
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        // A dumb terminal keeps prompt frameworks (p10k's instant prompt, starship)
        // from painting into the pipe.
        env["TERM"] = "dumb"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        guard let text = String(data: data, encoding: .utf8),
              let lo = text.range(of: begin),
              let hi = text.range(of: end, range: lo.upperBound..<text.endIndex)
        else { return nil }
        let path = String(text[lo.upperBound..<hi.lowerBound])
        return path.isEmpty ? nil : path
    }

    // MARK: - Finding a CLI

    /// The first executable named one of `names` on the user's shell PATH, or `nil`.
    ///
    /// Scanning the PATH ourselves rather than running `command -v` per name keeps
    /// this to a single shell spawn for the whole app, and sidesteps an interactive
    /// rc file's banner ending up parsed as a file path.
    static func which(_ names: [String]) -> String? {
        let fm = FileManager.default
        for dir in pathDirs where !dir.isEmpty {
            for name in names {
                let p = "\(dir)/\(name)"
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    // MARK: - Spawning a CLI

    /// **The only way to spawn an agent CLI.** Hands back a `Process` with its
    /// executable, arguments, working directory and — the part that keeps getting
    /// forgotten — its `environment` already set. Callers attach their own stdio and
    /// call `run()`.
    ///
    /// This exists as a constructor rather than an environment *getter* on purpose.
    /// The environment is what makes a CLI spawn work at all, and a `Process` whose
    /// `environment` is left alone inherits launchd's — a PATH with no `node` in it,
    /// no proxy, and (for a sandboxed context) no `HOME`. That version compiles, runs
    /// fine on a machine with a system-wide node, and dies with
    /// `env: node: No such file or directory` on a machine using a version manager.
    /// It shipped once (the agent-task spawn built its environment by hand and
    /// skipped the PATH work), so the environment is no longer something a caller can
    /// forget: `childEnvironment` is private, and this is the only door.
    ///
    /// Anything a spawn needs *every* time belongs here, not at the call sites.
    static func makeProcess(_ binary: String,
                            _ arguments: [String],
                            cwd: URL? = nil) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = arguments
        if let cwd { p.currentDirectoryURL = cwd }
        p.environment = childEnvironment(for: binary)
        return p
    }

    /// The environment a spawned CLI gets: the inherited one, plus a guaranteed
    /// `HOME` (so it finds its `~/.<cli>` auth file from a GUI context), a `PATH`
    /// that can resolve `node` for a shebang script, the proxy `ProxyConfig`
    /// resolves, and the two flags every one of these spawns wants:
    ///
    ///  - `DISABLE_AUTOUPDATER` — nothing Notch spawns is a session the user is
    ///    watching, so a background self-update is only ever a way for a CLI to
    ///    change versions underneath a run.
    ///  - `NO_COLOR` — every spawn is headless and has its output parsed. These CLIs
    ///    only emit SGR codes on a TTY, but a `FORCE_COLOR` in the user's own
    ///    environment (which is inherited here) would wrap the output in escapes and
    ///    break the parse.
    ///
    /// `binary`'s own directory leads the PATH: under a version manager that dir is
    /// where the matching `node` lives, and it's the one the shebang needs.
    ///
    /// Private — go through `makeProcess`.
    private static func childEnvironment(for binary: String) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }

        var dirs = [URL(fileURLWithPath: binary).deletingLastPathComponent().path]
        dirs += pathDirs
        dirs += (env["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin",
                 "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

        var seen = Set<String>()
        env["PATH"] = dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")

        env["DISABLE_AUTOUPDATER"] = "1"
        env["NO_COLOR"] = "1"

        ProxyConfig.apply(to: &env)
        return env
    }
}
