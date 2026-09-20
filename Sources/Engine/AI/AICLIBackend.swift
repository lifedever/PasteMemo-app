import Foundation

/// Runs a locally installed AI CLI as the transform backend — Claude Code, Codex, or
/// anything else that takes a prompt and prints an answer.
///
/// The appeal over an HTTP endpoint is billing: these CLIs carry their own auth (Claude
/// Code keeps an OAuth token in the login keychain), so a user with a subscription pays
/// nothing extra and never pastes an API key here. The cost is latency — a local `claude
/// -p` round-trip measures 4–8s against 1–2s for a hosted endpoint — which is tolerable
/// only because `aiTransform` already runs async behind a sticky toast.
///
/// Three knobs cover every CLI: the executable, an argument template, and how to read the
/// answer back out. Deliberately not a hardcoded two-way switch on claude/codex — the
/// presets just fill these fields in, and the user can still edit them.
struct AICLIConfig: Equatable, Sendable {
    /// Either a bare name resolved against `CLIResolver.searchPaths`, or an absolute path.
    var executable: String
    /// Whitespace-separated, single/double quotes respected. The `{prompt}` token is
    /// replaced whole (never split, never shell-escaped — arguments go to `Process` as an
    /// array, so there is no shell to escape for). No `{prompt}` anywhere = send the
    /// prompt on stdin instead.
    var arguments: String
    /// Key to pull out of a JSON reply, e.g. `result` for `claude --output-format json`.
    /// Empty = the answer is stdout verbatim.
    var outputJSONKey: String
    var timeout: Double

    static let promptToken = "{prompt}"

    var deliversPromptOnStdin: Bool {
        !arguments.contains(Self.promptToken)
    }
}

/// Finds a CLI that the user installed for their shell, from an app that has no shell.
///
/// A GUI process inherits `PATH=/usr/bin:/bin:/usr/sbin:/sbin` from launchd — none of the
/// places these tools actually install to. Rather than pay for a login shell (`zsh -lc`
/// sources rc files, costing hundreds of ms and whatever side effects live in there), just
/// look in the handful of directories that matter and hand `Process` an augmented PATH so
/// the CLI's own child processes resolve too.
enum CLIResolver {
    /// Ordered by likelihood. `~/.local/bin` is where Claude Code's native installer puts
    /// its binary; the Homebrew pair covers Apple Silicon and Intel.
    static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.bun/bin",
            "\(home)/.deno/bin",
            "/usr/bin",
        ]
    }

    /// Absolute path for `name`, or nil if nothing executable turned up.
    /// An input that already looks like a path is checked as-is, not searched.
    static func resolve(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        for dir in searchDirectories {
            let candidate = dir + "/" + expanded
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// `PATH` with the search directories appended, for the child's own lookups.
    static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let extras = searchDirectories.filter { !existing.split(separator: ":").contains(Substring($0)) }
        env["PATH"] = ([existing] + extras).joined(separator: ":")
        return env
    }
}

/// Splits an argument template the way a shell would, minus the shell.
///
/// Only quoting and whitespace — no globbing, no variable expansion, no command
/// substitution. A template is a convenience for the settings field, not a script: what
/// the user types is what the CLI receives, so `$(rm -rf ~)` in there is an argument
/// containing those characters and nothing more.
enum CLIArgumentTokenizer {
    static func tokenize(_ template: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        var quote: Character?

        for char in template {
            if let q = quote {
                if char == q { quote = nil } else { current.append(char) }
                continue
            }
            switch char {
            case "'", "\"":
                quote = char
                hasCurrent = true
            case " ", "\t", "\n":
                if hasCurrent { tokens.append(current); current = ""; hasCurrent = false }
            default:
                current.append(char)
                hasCurrent = true
            }
        }
        if hasCurrent { tokens.append(current) }
        return tokens
    }

    /// Tokenize, then swap the `{prompt}` token for the real text. Substitution happens
    /// after splitting, so a prompt with spaces or quotes stays one argument.
    static func buildArguments(template: String, prompt: String) -> [String] {
        tokenize(template).map { $0 == AICLIConfig.promptToken ? prompt : $0 }
    }
}

/// One-way flag, set by the timeout task and read after the process exits.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func fire() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    var fired: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// A continuation several parties may try to complete; the first one wins, the rest are
/// no-ops. Lets the timeout path end a wait that the happy path would also have ended.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var resolved: T?
    private var done = false

    func resume(_ value: T) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let waiting = continuation
        continuation = nil
        if waiting == nil { resolved = value }
        lock.unlock()
        waiting?.resume(returning: value)
    }

    /// Call at most once.
    func wait() async -> T {
        await withCheckedContinuation { cont in
            lock.lock()
            if done, let value = resolved {
                resolved = nil
                lock.unlock()
                cont.resume(returning: value)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }
}

/// Drains a pipe through `readabilityHandler` instead of a blocked thread.
///
/// The blocking alternative (`readToEnd` on a dispatch queue) can't be interrupted: a CLI
/// that spawns helpers — `claude` starts MCP servers — leaves those children holding the
/// write end after the parent is terminated, so the read never sees EOF and the whole
/// transform hangs past its timeout. Here the timeout can just take whatever arrived.
private final class PipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let completion = OneShot<Data>()
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let chunk = h.availableData
            if chunk.isEmpty {
                self.finish()
            } else {
                self.lock.lock()
                self.buffer.append(chunk)
                self.lock.unlock()
            }
        }
    }

    /// EOF, or the timeout giving up — whichever comes first.
    func finish() {
        handle.readabilityHandler = nil
        lock.lock()
        let data = buffer
        lock.unlock()
        completion.resume(data)
    }

    func wait() async -> Data { await completion.wait() }
}

/// Spawns the CLI and reads one answer back.
struct AICLIBackend: Sendable {
    let config: AICLIConfig

    init(config: AICLIConfig) {
        self.config = config
    }

    // MARK: - Public

    func transform(prompt: String, content: String) async throws -> String {
        let full = AIClient.systemPrompt + "\n\n"
            + prompt.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n---\n\n" + content
        let reply = try await run(prompt: full)
        return AIClient.stripFences(AIClient.stripThinking(reply).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testConnection() async throws -> String {
        try await run(prompt: "Reply with the single word OK.")
    }

    // MARK: - Execution

    func run(prompt: String) async throws -> String {
        guard !config.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.notConfigured
        }
        guard let executablePath = CLIResolver.resolve(config.executable) else {
            throw AIError.cliNotFound(config.executable)
        }
        let stdinText = config.deliversPromptOnStdin ? prompt : nil
        let arguments = CLIArgumentTokenizer.buildArguments(template: config.arguments, prompt: prompt)

        let result = try await Self.execute(
            executablePath: executablePath, arguments: arguments,
            stdinText: stdinText, timeout: config.timeout
        )

        guard result.exitCode == 0 else {
            // The CLIs put diagnostics on stderr and nothing useful on stdout when they
            // fail; fall back to stdout only if stderr was silent.
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            throw AIError.cliFailed(exitCode: result.exitCode, message: Self.firstMeaningfulLine(message))
        }
        let answer = try Self.extractAnswer(stdout: result.stdout, jsonKey: config.outputJSONKey)
        guard !answer.isEmpty else { throw AIError.emptyResponse }
        return answer
    }

    struct ProcessResult: Sendable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
    }

    static func execute(executablePath: String, arguments: [String],
                        stdinText: String?, timeout: Double) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = CLIResolver.augmentedEnvironment()
        // Run from the home directory: these CLIs pick up project config from the working
        // directory, and the app's cwd ("/") is meaningless to them.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe: Pipe?
        if stdinText != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inPipe = pipe
        } else {
            // Not merely tidy: `codex exec` with the prompt in argv still blocks waiting
            // for stdin EOF when stdin is an unwritten pipe, and hangs forever.
            process.standardInput = FileHandle.nullDevice
            inPipe = nil
        }

        // Both pipes drain concurrently — a CLI filling one buffer while we ignored the
        // other would deadlock. `claude` alone writes MCP warnings to stderr.
        let outReader = PipeReader(outPipe.fileHandleForReading)
        let errReader = PipeReader(errPipe.fileHandleForReading)
        let exited = OneShot<Void>()
        process.terminationHandler = { _ in exited.resume(()) }

        do {
            try process.run()
        } catch {
            outReader.finish()
            errReader.finish()
            throw AIError.cliFailed(exitCode: -1, message: error.localizedDescription)
        }

        if let stdinText, let inPipe {
            let handle = inPipe.fileHandleForWriting
            try? handle.write(contentsOf: Data(stdinText.utf8))
            try? handle.close()
        }

        // Records whether *we* killed it. Without this the check below can't tell a
        // timeout from a CLI that segfaulted or was killed from Activity Monitor — both
        // exit via `.uncaughtSignal`.
        let killedByTimeout = TimeoutFlag()
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
            if process.isRunning {
                killedByTimeout.fire()
                process.terminate()
                try await Task.sleep(nanoseconds: 1_000_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            // Unconditional: the process may have exited while an orphaned helper still
            // holds the write ends, so EOF never arrives. Take what got through and stop.
            exited.resume(())
            outReader.finish()
            errReader.finish()
        }
        defer { timeoutTask.cancel() }

        await exited.wait()
        let out = await outReader.wait()
        let err = await errReader.wait()

        if killedByTimeout.fired { throw AIError.timeout }
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    // MARK: - Output

    /// Raw stdout, or one key out of a JSON reply.
    ///
    /// `claude --output-format json` wraps the answer in an envelope (`result`, `model`,
    /// `usage`); pulling `result` out is also what keeps stray stdout noise from reaching
    /// the clipboard. Plain-text CLIs like `codex exec` need no key.
    static func extractAnswer(stdout: String, jsonKey: String) throws -> String {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = jsonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return trimmed }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.cliBadOutput(key: key)
        }
        // An envelope may report its own failure while the process still exits 0.
        if let isError = json["is_error"] as? Bool, isError {
            let message = (json[key] as? String) ?? (json["error"] as? String) ?? ""
            throw AIError.cliFailed(exitCode: 0, message: firstMeaningfulLine(message))
        }
        guard let value = json[key] else { throw AIError.cliBadOutput(key: key) }
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Some envelopes nest the text one level down as content parts.
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw AIError.cliBadOutput(key: key)
    }

    /// CLIs are chatty on failure (banners, stack traces). Take the first line that says
    /// something, capped, so the toast stays one line.
    static func firstMeaningfulLine(_ text: String, limit: Int = 200) -> String {
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(line.prefix(limit))
    }
}
