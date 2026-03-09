import Foundation

/// Executes scripts and captures output
public final class ScriptRunner: Sendable {
    public init() {}

    /// Run a script and return the result
    public func run(_ script: Script) async throws -> ScriptRun {
        var record = ScriptRun(
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
            process.executableURL = URL(fileURLWithPath: execPath)
            process.arguments = [script.path]
        } else {
            // Fallback: use /bin/sh
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
        }

        // Set working directory to script's directory
        let scriptDir = URL(fileURLWithPath: script.path).deletingLastPathComponent()
        process.currentDirectoryURL = scriptDir

        // Inherit environment and add common paths
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/local/opt/node/bin"]
        if let existingPath = env["PATH"] {
            env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
        }
        process.environment = env

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            record.output = String(data: stdoutData, encoding: .utf8) ?? ""
            record.errorOutput = String(data: stderrData, encoding: .utf8) ?? ""
            record.exitCode = process.terminationStatus
            record.finishedAt = Date()
            record.status = process.terminationStatus == 0 ? .success : .failure
        } catch {
            record.finishedAt = Date()
            record.status = .failure
            record.errorOutput = error.localizedDescription
        }

        return record
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
