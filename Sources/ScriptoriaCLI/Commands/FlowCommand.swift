import ArgumentParser
import Darwin
import Foundation
import ScriptoriaCore

struct FlowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flow",
        abstract: "Validate, compile and run Flow DSL",
        subcommands: [
            FlowValidateCommand.self,
            FlowCompileCommand.self,
            FlowRunCommand.self,
            FlowDryRunCommand.self,
        ]
    )
}

struct FlowValidateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "validate", abstract: "Validate a flow YAML file")

    @Argument(help: "Path to flow YAML")
    var flowPath: String

    @Flag(name: .long, help: "Skip filesystem run path existence check")
    var noFSCheck: Bool = false

    func run() async throws {
        do {
            _ = try FlowValidator.validateFile(
                atPath: flowPath,
                options: .init(checkFileSystem: !noFSCheck)
            )
            print("flow validate ok")
        } catch let error as FlowError {
            printFlowError(error, flowPath: flowPath)
            throw ExitCode.failure
        } catch {
            print("phase=validate error_code=flow.validate.schema_error error_message=\(error.localizedDescription) flow_path=\(flowPath)")
            throw ExitCode.failure
        }
    }
}

struct FlowCompileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "compile", abstract: "Compile flow YAML to canonical IR JSON")

    @Argument(help: "Path to flow YAML")
    var flowPath: String

    @Option(name: .long, help: "Output JSON file path")
    var out: String

    @Flag(name: .long, help: "Skip filesystem run path existence check")
    var noFSCheck: Bool = false

    func run() async throws {
        do {
            let ir = try FlowCompiler.compileFile(
                atPath: flowPath,
                options: .init(checkFileSystem: !noFSCheck)
            )
            let json = try FlowCompiler.renderCanonicalJSON(ir: ir)

            let outputPath = absolutePath(from: out)
            let outputURL = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try json.write(to: outputURL, atomically: true, encoding: .utf8)
            print("flow compile ok")
        } catch let error as FlowError {
            printFlowError(error, flowPath: flowPath)
            throw ExitCode.failure
        } catch {
            print("phase=compile error_code=flow.validate.schema_error error_message=\(error.localizedDescription) flow_path=\(flowPath)")
            throw ExitCode.failure
        }
    }
}

struct FlowRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Run a flow YAML")

    @Argument(help: "Path to flow YAML")
    var flowPath: String

    @Option(name: .customLong("var"), parsing: .upToNextOption, help: "Context override: key=value")
    var variable: [String] = []

    @Option(name: .long, help: "Global agent round hard cap")
    var maxAgentRounds: Int?

    @Flag(name: .long, help: "Disable interactive steer")
    var noSteer: Bool = false

    @Option(name: .long, help: "Send scripted command to agent turn (repeatable)")
    var command: [String] = []

    func run() async throws {
        let contextOverrides: [String: String]
        do {
            contextOverrides = try parseVarAssignments(variable)
        } catch let error as FlowError {
            printFlowError(error, flowPath: flowPath)
            throw ExitCode.failure
        } catch {
            print("phase=runtime-preflight error_code=flow.cli.var_key_invalid error_message=\(error.localizedDescription) flow_path=\(flowPath)")
            throw ExitCode.failure
        }

        let ir: FlowIR
        do {
            ir = try FlowCompiler.compileFile(atPath: flowPath)
        } catch let error as FlowError {
            let mapped = FlowError(
                code: error.code,
                message: error.message,
                phase: .runtimePreflight,
                stateID: error.stateID,
                fieldPath: error.fieldPath,
                line: error.line,
                column: error.column
            )
            printFlowError(mapped, flowPath: flowPath)
            throw ExitCode.failure
        } catch {
            print("phase=runtime-preflight error_code=flow.validate.schema_error error_message=\(error.localizedDescription) flow_path=\(flowPath)")
            throw ExitCode.failure
        }

        if let cap = maxAgentRounds, cap > ir.defaults.maxAgentRounds {
            print(
                "warning_code=flow.cli.max_agent_rounds_cap_ignored "
                + "warning_message=--max-agent-rounds (\(cap)) does not relax configured max_agent_rounds (\(ir.defaults.maxAgentRounds)); using configured cap."
            )
        }

        let interactiveSteerEnabled = shouldEnableInteractiveSteer(noSteer: noSteer)
        if interactiveSteerEnabled {
            print("[steer] Enter text to guide the running agent. Use /interrupt to stop.")
        }

        var commands = command
        if !noSteer && !interactiveSteerEnabled {
            commands.append(contentsOf: collectPipedSteerInputs())
        }
        let commandInput = interactiveSteerEnabled ? makeInteractiveSteerStream() : nil

        do {
            let result = try await FlowEngine().run(
                ir: ir,
                mode: .live,
                options: .init(
                    contextOverrides: contextOverrides,
                    maxAgentRoundsCap: maxAgentRounds,
                    noSteer: noSteer,
                    commands: commands
                ),
                commandInput: commandInput,
                logSink: { line in
                    print(line)
                }
            )
            for warning in result.warnings {
                print("warning_code=\(warning.code) warning_message=\(warning.message)")
            }
        } catch let error as FlowError {
            printFlowError(error, flowPath: flowPath)
            throw ExitCode.failure
        } catch {
            print("phase=runtime error_code=flow.validate.schema_error error_message=\(error.localizedDescription) flow_path=\(flowPath)")
            throw ExitCode.failure
        }
    }
}

struct FlowDryRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dry-run", abstract: "Run flow with fixture")

    @Argument(help: "Path to flow YAML")
    var flowPath: String

    @Option(name: .long, help: "Fixture JSON path")
    var fixture: String

    func run() async throws {
        let ir: FlowIR
        do {
            ir = try FlowCompiler.compileFile(atPath: flowPath)
        } catch let error as FlowError {
            let mapped = FlowError(
                code: error.code,
                message: error.message,
                phase: .runtimePreflight,
                stateID: error.stateID,
                fieldPath: error.fieldPath,
                line: error.line,
                column: error.column
            )
            printFlowError(mapped, flowPath: flowPath)
            throw ExitCode.failure
        } catch {
            print("phase=runtime-preflight error_code=flow.validate.schema_error error_message=\(error.localizedDescription) flow_path=\(flowPath)")
            throw ExitCode.failure
        }

        let dryFixture: FlowDryRunFixture
        do {
            dryFixture = try FlowDryRunFixture.load(fromPath: fixture)
        } catch let error as FlowError {
            printFlowError(error, flowPath: flowPath)
            throw ExitCode.failure
        } catch {
            print("phase=runtime-dry-run error_code=flow.validate.schema_error error_message=\(error.localizedDescription) flow_path=\(flowPath)")
            throw ExitCode.failure
        }

        do {
            let result = try await FlowEngine().run(
                ir: ir,
                mode: .dryRun(dryFixture),
                options: .init(),
                logSink: { line in
                    print(line)
                }
            )
            for warning in result.warnings {
                print("warning_code=\(warning.code) warning_message=\(warning.message)")
            }
        } catch let error as FlowError {
            printFlowError(error, flowPath: flowPath)
            throw ExitCode.failure
        } catch {
            print("phase=runtime-dry-run error_code=flow.validate.schema_error error_message=\(error.localizedDescription) flow_path=\(flowPath)")
            throw ExitCode.failure
        }
    }
}

private func parseVarAssignments(_ values: [String]) throws -> [String: String] {
    let regex = try NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*$")
    var result: [String: String] = [:]

    for raw in values {
        let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw FlowError(
                code: "flow.cli.var_key_invalid",
                message: "Invalid --var format: \(raw)",
                phase: .runtimePreflight
            )
        }

        let key = String(parts[0])
        let value = String(parts[1])

        let range = NSRange(location: 0, length: key.utf16.count)
        if regex.firstMatch(in: key, options: [], range: range) == nil {
            throw FlowError(
                code: "flow.cli.var_key_invalid",
                message: "Invalid --var key: \(key)",
                phase: .runtimePreflight
            )
        }

        result[key] = value
    }

    return result
}

private func printFlowError(_ error: FlowError, flowPath: String) {
    var fields: [String] = [
        "phase=\(error.phase.rawValue)",
        "error_code=\(error.code)",
        "error_message=\(sanitizeLogValue(error.message))",
        "flow_path=\(flowPath)"
    ]
    if let stateID = error.stateID {
        fields.append("state_id=\(stateID)")
    }
    if let fieldPath = error.fieldPath {
        fields.append("field_path=\(fieldPath)")
    }
    if let line = error.line {
        fields.append("line=\(line)")
    }
    if let column = error.column {
        fields.append("column=\(column)")
    }
    print(fields.joined(separator: " "))
}

private func sanitizeLogValue(_ value: String) -> String {
    value.replacingOccurrences(of: "\n", with: " ")
}

private func absolutePath(from raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("/") {
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
    if trimmed.hasPrefix("~/") {
        let expanded = NSString(string: trimmed).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
    return URL(fileURLWithPath: trimmed, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL
        .path
}

private func collectPipedSteerInputs() -> [String] {
    let stdinFD = FileHandle.standardInput.fileDescriptor
    // Avoid blocking interactive terminals; only consume piped stdin.
    guard isatty(stdinFD) == 0 else {
        return []
    }

    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty,
          let raw = String(data: data, encoding: .utf8) else {
        return []
    }

    return raw
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func shouldEnableInteractiveSteer(noSteer: Bool) -> Bool {
    !noSteer && isatty(fileno(stdin)) == 1
}

private func makeInteractiveSteerStream() -> AsyncStream<String> {
    AsyncStream { continuation in
        let readerTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                guard let line = readLine(strippingNewline: true) else {
                    break
                }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    continue
                }
                continuation.yield(trimmed)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            readerTask.cancel()
        }
    }
}
