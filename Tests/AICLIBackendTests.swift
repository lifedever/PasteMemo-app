import Foundation
import Testing
@testable import PasteMemo

/// Local-CLI backend: argument templating, answer extraction, executable lookup, and a
/// handful of real spawns against system binaries (`cat`, `echo`, `sh`) so the process
/// plumbing — stdin delivery, exit codes, timeouts — is covered without needing Claude
/// Code or Codex installed on the machine running the tests.
@Suite("AICLIBackend")
struct AICLIBackendTests {

    // MARK: - Tokenizer

    @Test("Splits on whitespace")
    func tokenizePlain() {
        #expect(CLIArgumentTokenizer.tokenize("-p {prompt} --max-turns 1")
                == ["-p", "{prompt}", "--max-turns", "1"])
    }

    @Test("Quoted runs stay one argument")
    func tokenizeQuotes() {
        #expect(CLIArgumentTokenizer.tokenize("--allowedTools 'Bash(git diff *),Read' -p")
                == ["--allowedTools", "Bash(git diff *),Read", "-p"])
        #expect(CLIArgumentTokenizer.tokenize(#"--flag "two words""#) == ["--flag", "two words"])
    }

    @Test("Empty quotes produce an empty argument, not a dropped one")
    func tokenizeEmptyQuoted() {
        #expect(CLIArgumentTokenizer.tokenize("--flag '' --next") == ["--flag", "", "--next"])
    }

    @Test("Extra whitespace collapses")
    func tokenizeWhitespace() {
        #expect(CLIArgumentTokenizer.tokenize("  -p   \t {prompt}  ") == ["-p", "{prompt}"])
        #expect(CLIArgumentTokenizer.tokenize("").isEmpty)
    }

    @Test("Prompt substitution keeps the prompt as a single argument")
    func substitutePrompt() {
        let args = CLIArgumentTokenizer.buildArguments(
            template: "-p {prompt} --output-format json",
            prompt: "rewrite this; rm -rf ~ \"quoted\" $(whoami)"
        )
        #expect(args == ["-p", "rewrite this; rm -rf ~ \"quoted\" $(whoami)", "--output-format", "json"])
    }

    @Test("Only a standalone {prompt} token is replaced")
    func substituteOnlyWholeToken() {
        let args = CLIArgumentTokenizer.buildArguments(template: "--x=file{prompt}.txt", prompt: "P")
        #expect(args == ["--x=file{prompt}.txt"])
    }

    @Test("No {prompt} in the template means stdin delivery")
    func stdinDetection() {
        #expect(AICLIConfig(executable: "cat", arguments: "", outputJSONKey: "", timeout: 10)
            .deliversPromptOnStdin)
        #expect(!AICLIConfig(executable: "claude", arguments: "-p {prompt}", outputJSONKey: "", timeout: 10)
            .deliversPromptOnStdin)
    }

    // MARK: - Answer extraction

    @Test("Empty key takes stdout verbatim")
    func extractRaw() throws {
        #expect(try AICLIBackend.extractAnswer(stdout: "  hello world \n", jsonKey: "") == "hello world")
    }

    @Test("Named key is pulled out of the JSON envelope")
    func extractJSONKey() throws {
        let stdout = #"{"type":"result","result":"HELLO","model":"claude-x","usage":{"input_tokens":5}}"#
        #expect(try AICLIBackend.extractAnswer(stdout: stdout, jsonKey: "result") == "HELLO")
    }

    @Test("Content-part arrays are joined")
    func extractContentParts() throws {
        let stdout = #"{"result":[{"text":"foo"},{"text":"bar"}]}"#
        #expect(try AICLIBackend.extractAnswer(stdout: stdout, jsonKey: "result") == "foobar")
    }

    @Test("An envelope reporting its own failure throws, exit code 0 notwithstanding")
    func extractIsError() {
        let stdout = #"{"is_error":true,"result":"Credit balance is too low"}"#
        #expect(throws: AIError.cliFailed(exitCode: 0, message: "Credit balance is too low")) {
            try AICLIBackend.extractAnswer(stdout: stdout, jsonKey: "result")
        }
    }

    @Test("Non-JSON stdout under a JSON key is an error, not silent garbage")
    func extractBadJSON() {
        #expect(throws: AIError.cliBadOutput(key: "result")) {
            try AICLIBackend.extractAnswer(stdout: "not json at all", jsonKey: "result")
        }
    }

    @Test("Missing key is an error")
    func extractMissingKey() {
        #expect(throws: AIError.cliBadOutput(key: "result")) {
            try AICLIBackend.extractAnswer(stdout: #"{"other":"x"}"#, jsonKey: "result")
        }
    }

    @Test("Error text collapses to its first non-empty line")
    func firstLine() {
        #expect(AICLIBackend.firstMeaningfulLine("\n\n  boom happened  \nstack frame\n") == "boom happened")
        #expect(AICLIBackend.firstMeaningfulLine("") == "")
        #expect(AICLIBackend.firstMeaningfulLine(String(repeating: "x", count: 500)).count == 200)
    }

    // MARK: - Executable lookup

    @Test("An absolute path is checked, not searched")
    func resolveAbsolute() {
        #expect(CLIResolver.resolve("/bin/cat") == "/bin/cat")
        #expect(CLIResolver.resolve("/bin/definitely-not-here") == nil)
    }

    @Test("A bare name is found on the search path")
    func resolveBareName() {
        // /usr/bin is in searchDirectories, and `env` ships with macOS.
        #expect(CLIResolver.resolve("env") == "/usr/bin/env")
        #expect(CLIResolver.resolve("pastememo-no-such-cli") == nil)
        #expect(CLIResolver.resolve("") == nil)
    }

    @Test("Augmented PATH includes the install directories a GUI process lacks")
    func augmentedPath() {
        let path = CLIResolver.augmentedEnvironment()["PATH"] ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(path.contains("\(home)/.local/bin"))
        #expect(path.contains("/opt/homebrew/bin"))
    }

    // MARK: - Real process round-trips

    @Test("Prompt passed as an argument comes back on stdout")
    func runWithArgumentPrompt() async throws {
        let backend = AICLIBackend(config: AICLIConfig(
            executable: "/bin/echo", arguments: "{prompt}", outputJSONKey: "", timeout: 30))
        #expect(try await backend.run(prompt: "round trip") == "round trip")
    }

    @Test("Prompt with no {prompt} token is delivered on stdin")
    func runWithStdinPrompt() async throws {
        let backend = AICLIBackend(config: AICLIConfig(
            executable: "/bin/cat", arguments: "", outputJSONKey: "", timeout: 30))
        #expect(try await backend.run(prompt: "via stdin") == "via stdin")
    }

    /// Single-quoting is what keeps the JSON's own double quotes intact through the
    /// tokenizer — the same protection a template like `--allowedTools 'Bash(git diff *)'`
    /// relies on.
    @Test("A JSON-emitting command is unwrapped by key")
    func runWithJSONEnvelope() async throws {
        let backend = AICLIBackend(config: AICLIConfig(
            executable: "/bin/echo",
            arguments: #"'{"result":"unwrapped"}'"#,
            outputJSONKey: "result", timeout: 30))
        #expect(try await backend.run(prompt: "ignored") == "unwrapped")
    }

    @Test("A missing executable is reported before anything is spawned")
    func runMissingExecutable() async {
        let backend = AICLIBackend(config: AICLIConfig(
            executable: "pastememo-no-such-cli", arguments: "{prompt}", outputJSONKey: "", timeout: 5))
        await #expect(throws: AIError.cliNotFound("pastememo-no-such-cli")) {
            try await backend.run(prompt: "x")
        }
    }

    @Test("An empty executable reads as unconfigured, not as a lookup failure")
    func runEmptyExecutable() async {
        let backend = AICLIBackend(config: AICLIConfig(
            executable: "  ", arguments: "", outputJSONKey: "", timeout: 5))
        await #expect(throws: AIError.notConfigured) { try await backend.run(prompt: "x") }
    }

    @Test("A non-zero exit surfaces the CLI's stderr")
    func runNonZeroExit() async throws {
        let backend = AICLIBackend(config: AICLIConfig(
            executable: "/bin/sh", arguments: "-c 'echo boom >&2; exit 3'",
            outputJSONKey: "", timeout: 30))
        do {
            _ = try await backend.run(prompt: "x")
            Issue.record("expected a failure")
        } catch let error as AIError {
            #expect(error == .cliFailed(exitCode: 3, message: "boom"))
        }
    }

    @Test("Empty output is reported rather than silently pasting nothing")
    func runEmptyOutput() async {
        let backend = AICLIBackend(config: AICLIConfig(
            executable: "/usr/bin/true", arguments: "", outputJSONKey: "", timeout: 30))
        await #expect(throws: AIError.emptyResponse) { try await backend.run(prompt: "x") }
    }

    @Test("A hung command is killed at the timeout", .timeLimit(.minutes(1)))
    func runTimeout() async {
        let backend = AICLIBackend(config: AICLIConfig(
            executable: "/bin/sleep", arguments: "30", outputJSONKey: "", timeout: 1))
        let started = Date()
        await #expect(throws: AIError.timeout) { try await backend.run(prompt: "x") }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    /// The shape that hangs a blocking reader: the command exits immediately, but a
    /// background child inherits stdout and holds it open, so EOF never arrives. `claude`
    /// does this for real — it starts MCP server processes. The timeout has to end the
    /// wait even though the process we spawned is already gone.
    @Test("A command whose orphaned child holds stdout still returns", .timeLimit(.minutes(1)))
    func runOrphanedChildHoldsPipe() async throws {
        let backend = AICLIBackend(config: AICLIConfig(
            executable: "/bin/sh",
            arguments: "-c 'echo answer; sleep 25 & exit 0'",
            outputJSONKey: "", timeout: 2))
        let started = Date()
        let reply = try await backend.run(prompt: "x")
        let elapsed = Date().timeIntervalSince(started)
        #expect(reply == "answer")
        // Bounded by the timeout, not by the orphan's 25s lifetime.
        #expect(elapsed < 15, "took \(elapsed)s — the read waited on an EOF that never came")
    }

    @Test("transform sends the system prompt, the instruction and the text as one payload")
    func transformPayload() async throws {
        // `cat` echoes stdin back, so the reply *is* what the CLI received.
        let backend = AICLIBackend(config: AICLIConfig(
            executable: "/bin/cat", arguments: "", outputJSONKey: "", timeout: 30))
        let reply = try await backend.transform(prompt: "Uppercase it", content: "hello")
        #expect(reply.contains("Uppercase it"))
        #expect(reply.contains("hello"))
        #expect(reply.contains(AIClient.systemPrompt))
    }

    @Test("Fenced replies are unwrapped like the hosted path")
    func transformStripsFences() async throws {
        let backend = AICLIBackend(config: AICLIConfig(
            executable: "/bin/echo", arguments: "```\nfenced answer\n```",
            outputJSONKey: "", timeout: 30))
        #expect(try await backend.transform(prompt: "p", content: "c") == "fenced answer")
    }
}

/// How `cliSnapshot()` resolves the four fields, which differs by preset: a named agent
/// takes its command line from the preset so later corrections reach existing installs,
/// while Custom is whatever the user typed.
@Suite("AICLIPreset resolution", .serialized)
struct AICLIPresetResolutionTests {

    private let keys = [
        AIProviderSettings.cliPresetKey, AIProviderSettings.cliExecutableKey,
        AIProviderSettings.cliExecutableOverrideKey, AIProviderSettings.cliArgumentsKey,
        AIProviderSettings.cliOutputKeyKey, AIProviderSettings.cliModelKey,
    ]

    private func withCleanDefaults(_ body: () -> Void) {
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        body()
    }

    @Test("A named preset ignores stored arguments in favour of its own")
    func presetArgumentsWinOverStorage() {
        withCleanDefaults {
            AIProviderSettings.cliPreset = .claudeCode
            AIProviderSettings.cliArguments = "--stale-flag-from-an-older-build"
            AIProviderSettings.cliOutputJSONKey = "stale"
            let snapshot = AIProviderSettings.cliSnapshot()
            #expect(snapshot.executable == "claude")
            #expect(snapshot.arguments == AICLIPreset.claudeCode.arguments)
            #expect(snapshot.outputJSONKey == "result")
        }
    }

    @Test("Custom uses exactly what was typed")
    func customUsesStorage() {
        withCleanDefaults {
            AIProviderSettings.cliPreset = .custom
            AIProviderSettings.cliExecutable = "my-tool"
            AIProviderSettings.cliArguments = "--rewrite {prompt}"
            AIProviderSettings.cliOutputJSONKey = "text"
            let snapshot = AIProviderSettings.cliSnapshot()
            #expect(snapshot.executable == "my-tool")
            #expect(snapshot.arguments == "--rewrite {prompt}")
            #expect(snapshot.outputJSONKey == "text")
        }
    }

    @Test("An override path beats the preset's bare name")
    func overrideBeatsPresetName() {
        withCleanDefaults {
            AIProviderSettings.cliPreset = .codex
            AIProviderSettings.cliExecutableOverride = "/opt/custom/bin/codex"
            #expect(AIProviderSettings.cliSnapshot().executable == "/opt/custom/bin/codex")
        }
    }

    /// The reason the override lives in its own key: a user who configured Custom, tried
    /// a preset, then came back must find their command and arguments intact.
    @Test("Switching to a preset and back leaves the Custom setup alone")
    func presetRoundTripPreservesCustom() {
        withCleanDefaults {
            AIProviderSettings.cliPreset = .custom
            AIProviderSettings.cliExecutable = "my-tool"
            AIProviderSettings.cliArguments = "--rewrite {prompt}"

            AIProviderSettings.cliPreset = .claudeCode
            AIProviderSettings.cliExecutableOverride = "/somewhere/claude"
            #expect(AIProviderSettings.cliSnapshot().executable == "/somewhere/claude")

            AIProviderSettings.cliPreset = .custom
            let snapshot = AIProviderSettings.cliSnapshot()
            #expect(snapshot.executable == "my-tool")
            #expect(snapshot.arguments == "--rewrite {prompt}")
        }
    }

    @Test("A chosen model is appended as --model")
    func modelAppendedToPresetArguments() {
        withCleanDefaults {
            AIProviderSettings.cliPreset = .claudeCode
            AIProviderSettings.cliModel = "opus"
            let args = CLIArgumentTokenizer.tokenize(AIProviderSettings.cliSnapshot().arguments)
            #expect(args.contains("--model"))
            #expect(args.last == "opus")
        }
    }

    @Test("No model chosen means no --model flag, so the agent keeps its own default")
    func noModelNoFlag() {
        withCleanDefaults {
            AIProviderSettings.cliPreset = .codex
            #expect(!AIProviderSettings.cliSnapshot().arguments.contains("--model"))
        }
    }

    @Test("A model name stays one argument and can't break out of its quotes")
    func modelIsOneArgument() {
        withCleanDefaults {
            AIProviderSettings.cliPreset = .claudeCode
            AIProviderSettings.cliModel = "weird' --dangerous-flag"
            let args = CLIArgumentTokenizer.tokenize(AIProviderSettings.cliSnapshot().arguments)
            #expect(args.last == "weird --dangerous-flag")
            #expect(!args.contains("--dangerous-flag"))
        }
    }

    @Test("Custom gets no model flag — the user writes the whole command line")
    func customIgnoresModelField() {
        withCleanDefaults {
            AIProviderSettings.cliPreset = .custom
            AIProviderSettings.cliArguments = "--rewrite {prompt}"
            AIProviderSettings.cliModel = "opus"
            #expect(AIProviderSettings.cliSnapshot().arguments == "--rewrite {prompt}")
        }
    }

    @Test("A preset is configured without the user typing anything")
    func presetIsConfiguredOutOfTheBox() {
        withCleanDefaults {
            let savedMode = AIProviderSettings.mode
            defer { AIProviderSettings.mode = savedMode }
            AIProviderSettings.mode = .local
            AIProviderSettings.cliPreset = .claudeCode
            #expect(AIProviderSettings.isConfigured)
            AIProviderSettings.cliPreset = .custom
            #expect(!AIProviderSettings.isConfigured)
        }
    }
}
