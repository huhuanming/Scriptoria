import Foundation

public final class MemoryManager: Sendable {
    private let baseDirectory: String

    public init(baseDirectory: String) {
        self.baseDirectory = baseDirectory
    }

    public convenience init(config: Config) {
        self.init(baseDirectory: config.memoryDirectory)
    }

    public func taskRootDirectory(taskId: Int?, taskName: String) -> String {
        _ = taskId
        let folder = sanitizePathComponent(taskName)
        return "\(baseDirectory)/\(folder)"
    }

    public func taskDirectory(taskId: Int?, taskName: String) -> String {
        "\(taskRootDirectory(taskId: taskId, taskName: taskName))/task"
    }

    public func workspacePath(taskId: Int?, taskName: String) -> String {
        "\(taskRootDirectory(taskId: taskId, taskName: taskName))/workspace.md"
    }

    public func readWorkspaceMemory(taskId: Int?, taskName: String) -> String? {
        let path = workspacePath(taskId: taskId, taskName: taskName)
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    @discardableResult
    public func writeTaskMemory(
        taskId: Int?,
        taskName: String,
        script: Script,
        scriptRun: ScriptRun,
        agentResult: AgentExecutionResult
    ) throws -> String {
        let fm = FileManager.default
        let dir = taskDirectory(taskId: taskId, taskName: taskName)
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let timestamp = formatTimestamp(agentResult.finishedAt)
        var path = "\(dir)/\(timestamp).md"
        var suffix = 1
        while fm.fileExists(atPath: path) {
            path = "\(dir)/\(timestamp)-\(suffix).md"
            suffix += 1
        }

        let good = buildGoodPoints(scriptRun: scriptRun, agentResult: agentResult)
        let bad = buildBadPoints(scriptRun: scriptRun, agentResult: agentResult)
        let experience = buildExperiencePoints(scriptRun: scriptRun, agentResult: agentResult)

        let content = """
            # Task Memory

            - task_id: \(taskId.map(String.init) ?? "n/a")
            - task_name: \(taskName)
            - script: \(script.title)
            - script_run_id: \(scriptRun.id.uuidString)
            - agent_thread_id: \(agentResult.threadId)
            - agent_turn_id: \(agentResult.turnId)
            - model: \(agentResult.model)
            - started_at: \(isoString(agentResult.startedAt))
            - finished_at: \(isoString(agentResult.finishedAt))
            - status: \(agentResult.status.rawValue)

            ## Outcome

            \(agentResult.finalMessage.isEmpty ? "(no final message)" : agentResult.finalMessage)

            ## Good
            \(good.map { "- \($0)" }.joined(separator: "\n"))

            ## Bad
            \(bad.map { "- \($0)" }.joined(separator: "\n"))

            ## Experience
            \(experience.map { "- \($0)" }.joined(separator: "\n"))
            """

        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @discardableResult
    public func summarizeWorkspaceMemory(taskId: Int?, taskName: String) throws -> String {
        let fm = FileManager.default
        let taskDir = taskDirectory(taskId: taskId, taskName: taskName)
        let rootDir = taskRootDirectory(taskId: taskId, taskName: taskName)
        if !fm.fileExists(atPath: rootDir) {
            try fm.createDirectory(atPath: rootDir, withIntermediateDirectories: true)
        }

        let files = (try? fm.contentsOfDirectory(atPath: taskDir))?
            .filter { $0.hasSuffix(".md") }
            .sorted() ?? []

        var goodCounts: [String: Int] = [:]
        var badCounts: [String: Int] = [:]
        var experienceCounts: [String: Int] = [:]
        var latestFiles: [String] = []

        for file in files {
            let path = "\(taskDir)/\(file)"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let sections = parseSections(from: text)
            count(section: sections.good, into: &goodCounts)
            count(section: sections.bad, into: &badCounts)
            count(section: sections.experience, into: &experienceCounts)
            latestFiles.append(file)
        }

        let workspacePath = workspacePath(taskId: taskId, taskName: taskName)
        let generatedAt = isoString(Date())

        let content = """
            # Workspace Memory

            - task_id: \(taskId.map(String.init) ?? "n/a")
            - task_name: \(taskName)
            - generated_at: \(generatedAt)
            - task_memory_count: \(files.count)

            ## Top Good Patterns
            \(renderTopCounts(goodCounts))

            ## Top Bad Patterns
            \(renderTopCounts(badCounts))

            ## Top Experience Patterns
            \(renderTopCounts(experienceCounts))

            ## Source Task Memories
            \(latestFiles.isEmpty ? "- (none)" : latestFiles.map { "- \($0)" }.joined(separator: "\n"))
            """

        try content.write(toFile: workspacePath, atomically: true, encoding: .utf8)
        return workspacePath
    }

    private func buildGoodPoints(scriptRun: ScriptRun, agentResult: AgentExecutionResult) -> [String] {
        var points: [String] = []
        if scriptRun.status == .success {
            points.append("Script stage completed successfully.")
        }
        if agentResult.status == .completed {
            points.append("Agent stage reached a completed state.")
        }
        if !agentResult.finalMessage.isEmpty {
            points.append("Final answer was produced.")
        }
        if points.isEmpty {
            points.append("No clear positive signal in this run.")
        }
        return points
    }

    private func buildBadPoints(scriptRun: ScriptRun, agentResult: AgentExecutionResult) -> [String] {
        var points: [String] = []
        if scriptRun.status != .success {
            points.append("Script stage ended with status '\(scriptRun.status.rawValue)' and exit code \(scriptRun.exitCode ?? -1).")
        }
        if agentResult.status == .failed {
            points.append("Agent stage failed before completion.")
        }
        if agentResult.status == .interrupted {
            points.append("Agent stage was interrupted before normal completion.")
        }
        if agentResult.finalMessage.isEmpty {
            points.append("No final answer was captured from the agent.")
        }
        if points.isEmpty {
            points.append("No major issues observed in this run.")
        }
        return points
    }

    private func buildExperiencePoints(scriptRun: ScriptRun, agentResult: AgentExecutionResult) -> [String] {
        var points: [String] = []
        points.append("Model used: \(agentResult.model).")
        points.append("Agent duration: \(formatDuration(agentResult.finishedAt.timeIntervalSince(agentResult.startedAt))).")
        if !scriptRun.output.isEmpty {
            points.append("Script stdout provided useful context for downstream agent execution.")
        }
        if !scriptRun.errorOutput.isEmpty {
            points.append("Script stderr should be reviewed before next run to reduce downstream noise.")
        }
        if agentResult.status == .completed && !agentResult.finalMessage.isEmpty {
            points.append("Final answer quality improved when execution context included prior memory.")
        }
        return points
    }

    private func parseSections(from markdown: String) -> (good: [String], bad: [String], experience: [String]) {
        enum Section {
            case none
            case good
            case bad
            case experience
        }

        var section: Section = .none
        var good: [String] = []
        var bad: [String] = []
        var experience: [String] = []

        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("## Good") {
                section = .good
                continue
            }
            if line.hasPrefix("## Bad") {
                section = .bad
                continue
            }
            if line.hasPrefix("## Experience") {
                section = .experience
                continue
            }
            guard line.hasPrefix("- ") else { continue }
            let value = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch section {
            case .good:
                good.append(value)
            case .bad:
                bad.append(value)
            case .experience:
                experience.append(value)
            case .none:
                break
            }
        }
        return (good, bad, experience)
    }

    private func count(section: [String], into dict: inout [String: Int]) {
        for line in section {
            dict[line, default: 0] += 1
        }
    }

    private func renderTopCounts(_ counts: [String: Int]) -> String {
        if counts.isEmpty {
            return "- (none)"
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(10)
            .map { "- [\($0.value)x] \($0.key)" }
            .joined(separator: "\n")
    }

    private func sanitizePathComponent(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "task" }

        let forbidden = CharacterSet(charactersIn: "/:\0")
        var scalars: [UnicodeScalar] = []
        var previousDash = false

        for scalar in trimmed.unicodeScalars {
            let shouldReplace = forbidden.contains(scalar) || CharacterSet.newlines.contains(scalar)
            if shouldReplace {
                if !previousDash {
                    scalars.append("-")
                    previousDash = true
                }
            } else {
                scalars.append(scalar)
                previousDash = false
            }
        }

        let sanitized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return sanitized.isEmpty ? "task" : sanitized
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return String(format: "%.0fms", seconds * 1000)
        }
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m)m \(s)s"
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmssSSS"
        return formatter.string(from: date)
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
