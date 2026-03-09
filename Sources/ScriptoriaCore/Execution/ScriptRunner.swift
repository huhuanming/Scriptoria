import Foundation

/// Executes scripts and captures output
public final class ScriptRunner: Sendable {
    public init() {}

    /// Run a script and return the result
    public func run(_ script: Script) async throws -> ScriptRun {
        try await runStreaming(script, onOutput: nil)
    }

    /// Run a script with real-time streaming output.
    /// `onOutput` is called on each chunk of stdout/stderr data: (text, isStderr)
    public func runStreaming(
        _ script: Script,
        onOutput: (@Sendable (String, Bool) -> Void)?
    ) async throws -> ScriptRun {
        try await runStreaming(script, runId: UUID(), logManager: nil, onStart: nil, onOutput: onOutput)
    }

    /// Run a script with persistent logging, PID tracking, and real-time streaming output.
    /// - Parameters:
    ///   - runId: The UUID to use for the ScriptRun record
    ///   - logManager: If provided, output is written to a log file on disk
    ///   - onStart: Called with the process PID immediately after launch
    ///   - onOutput: Called on each chunk of stdout/stderr data: (text, isStderr)
    public func runStreaming(
        _ script: Script,
        runId: UUID,
        logManager: LogManager?,
        onStart: (@Sendable (Int32) -> Void)?,
        onOutput: (@Sendable (String, Bool) -> Void)?
    ) async throws -> ScriptRun {
        var record = ScriptRun(
            id: runId,
            scriptId: script.id,
            scriptTitle: script.title
        )

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        // Determine interpreter
        let interpreter = script.interpreter == .auto
            ? detectInterpreter(for: script.path)
            : script.interpreter

        if interpreter == .binary {
            process.executableURL = URL(fileURLWithPath: script.path)
        } else if let execPath = interpreter.executablePath {
            // For interpreters that may be installed via version managers (nvm, pyenv, etc.),
            // resolve the actual path at runtime if the hardcoded path doesn't exist.
            let resolvedPath: String
            if FileManager.default.fileExists(atPath: execPath) {
                resolvedPath = execPath
            } else if let found = ScriptRunner.resolveExecutable(interpreter.executableName) {
                resolvedPath = found
            } else {
                resolvedPath = execPath
            }
            process.executableURL = URL(fileURLWithPath: resolvedPath)
            process.arguments = [script.path]
        } else {
            // Fallback: use /bin/sh
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
        }

        // Set working directory to script's directory
        let scriptDir = URL(fileURLWithPath: script.path).deletingLastPathComponent()
        process.currentDirectoryURL = scriptDir

        // Inherit full login shell environment (critical for launchd which has minimal PATH)
        var env = ScriptRunner.loginShellEnvironment() ?? ProcessInfo.processInfo.environment
        let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin"]
        if let existingPath = env["PATH"] {
            env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
        }
        process.environment = env

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Collect output in thread-safe storage
        let outputCollector = OutputCollector()

        // Capture runId and logManager for use in closures
        let capturedRunId = record.id
        let capturedLogManager = logManager

        // Set up streaming handlers if callback provided
        if let onOutput {
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let text = String(data: data, encoding: .utf8) {
                    outputCollector.appendStdout(text)
                    capturedLogManager?.append(text, to: capturedRunId)
                    onOutput(text, false)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let text = String(data: data, encoding: .utf8) {
                    outputCollector.appendStderr(text)
                    capturedLogManager?.append(text, to: capturedRunId)
                    onOutput(text, true)
                }
            }
        } else if capturedLogManager != nil {
            // Even without onOutput callback, write to log file
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let text = String(data: data, encoding: .utf8) {
                    outputCollector.appendStdout(text)
                    capturedLogManager?.append(text, to: capturedRunId)
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let text = String(data: data, encoding: .utf8) {
                    outputCollector.appendStderr(text)
                    capturedLogManager?.append(text, to: capturedRunId)
                }
            }
        }

        do {
            try process.run()

            // Capture PID and notify caller
            let pid = process.processIdentifier
            record.pid = pid
            onStart?(pid)

            // Wait for process on a background thread to avoid blocking
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }

            let hasHandlers = onOutput != nil || capturedLogManager != nil
            if hasHandlers {
                // Clean up handlers
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                // Read any remaining data
                let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if let text = String(data: remainingStdout, encoding: .utf8), !text.isEmpty {
                    outputCollector.appendStdout(text)
                    capturedLogManager?.append(text, to: capturedRunId)
                    onOutput?(text, false)
                }
                if let text = String(data: remainingStderr, encoding: .utf8), !text.isEmpty {
                    outputCollector.appendStderr(text)
                    capturedLogManager?.append(text, to: capturedRunId)
                    onOutput?(text, true)
                }
                record.output = outputCollector.stdout
                record.errorOutput = outputCollector.stderr
            } else {
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                record.output = String(data: stdoutData, encoding: .utf8) ?? ""
                record.errorOutput = String(data: stderrData, encoding: .utf8) ?? ""
            }

            record.exitCode = process.terminationStatus
            record.finishedAt = Date()
            if process.terminationReason == .uncaughtSignal {
                record.status = .cancelled
            } else {
                record.status = process.terminationStatus == 0 ? .success : .failure
            }
        } catch {
            record.finishedAt = Date()
            record.status = .failure
            record.errorOutput = error.localizedDescription
        }

        return record
    }

    // MARK: - Environment Resolution

    /// Resolve the full PATH and environment from the user's login shell.
    /// This ensures nvm, homebrew, and other tools are available even under launchd.
    private static func loginShellEnvironment() -> [String: String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-i", "-l", "-c", "env"]
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        proc.environment = ["HOME": NSHomeDirectory(), "USER": NSUserName()]
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            var env: [String: String] = [:]
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    env[String(parts[0])] = String(parts[1])
                }
            }
            return env.isEmpty ? nil : env
        } catch {
            return nil
        }
    }

    /// Resolve an interpreter executable via the user's login shell (handles nvm, etc.)
    private static func resolveExecutable(_ name: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-i", "-l", "-c", "which \(name)"]
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        proc.environment = ["HOME": NSHomeDirectory(), "USER": NSUserName()]
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }

    /// Detect interpreter from file extension or shebang
    public func detectInterpreter(for path: String) -> Interpreter {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()

        switch ext {
        case "sh": return .sh
        case "bash": return .bash
        case "zsh": return .zsh
        case "js", "mjs", "cjs": return .node
        case "py": return .python3
        case "rb": return .ruby
        case "scpt", "applescript": return .osascript
        default: break
        }

        // Try reading shebang
        if let handle = FileHandle(forReadingAtPath: path),
           let data = try? handle.read(upToCount: 256),
           let firstLine = String(data: data, encoding: .utf8)?.components(separatedBy: .newlines).first,
           firstLine.hasPrefix("#!") {
            let shebang = firstLine.lowercased()
            if shebang.contains("node") { return .node }
            if shebang.contains("python3") { return .python3 }
            if shebang.contains("python") { return .python }
            if shebang.contains("ruby") { return .ruby }
            if shebang.contains("bash") { return .bash }
            if shebang.contains("zsh") { return .zsh }
        }

        // Check if file is executable
        if FileManager.default.isExecutableFile(atPath: path) {
            return .binary
        }

        return .sh
    }
}

/// Thread-safe collector for streaming output
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _stdout = ""
    private var _stderr = ""

    var stdout: String { lock.withLock { _stdout } }
    var stderr: String { lock.withLock { _stderr } }

    func appendStdout(_ text: String) { lock.withLock { _stdout += text } }
    func appendStderr(_ text: String) { lock.withLock { _stderr += text } }
}
