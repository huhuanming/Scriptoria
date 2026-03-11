import Foundation

struct FlowResolvedRunPath {
    var absolutePath: String
    var irPath: String
}

enum FlowPathResolver {
    static func absolutePath(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        if trimmed.hasPrefix("~/") {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: trimmed, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path
    }

    static func resolveRunPath(
        _ run: String,
        flowDirectory: URL,
        phase: FlowPhase,
        checkFileSystem: Bool,
        stateID: String?
    ) throws -> FlowResolvedRunPath {
        let trimmed = run.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FlowErrors.schema("run must not be empty", field: "run")
        }

        let isAbsolute = trimmed.hasPrefix("/")
        let isHome = trimmed.hasPrefix("~/")
        let isExplicitRelative = trimmed.hasPrefix("./") || trimmed.hasPrefix("../")
        let containsSlash = trimmed.contains("/")

        if !(isAbsolute || isHome || isExplicitRelative || containsSlash) {
            let fieldPath = stateID.map { "states.\($0).run" } ?? "run"
            throw FlowErrors.pathKind(trimmed, phase: phase, stateID: stateID, fieldPath: fieldPath)
        }

        let absolutePath: String
        let irPath: String
        if isAbsolute {
            absolutePath = URL(fileURLWithPath: trimmed).standardizedFileURL.path
            irPath = absolutePath
        } else if isHome {
            absolutePath = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath).standardizedFileURL.path
            irPath = absolutePath
        } else {
            absolutePath = URL(fileURLWithPath: trimmed, relativeTo: flowDirectory).standardizedFileURL.path
            irPath = relativePath(from: flowDirectory.path, to: absolutePath)
        }

        if checkFileSystem {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory)
            let readable = FileManager.default.isReadableFile(atPath: absolutePath)
            if !exists || isDirectory.boolValue || !readable {
                let fieldPath = stateID.map { "states.\($0).run" } ?? "run"
                throw FlowErrors.pathNotFound(
                    absolutePath,
                    phase: phase,
                    stateID: stateID,
                    fieldPath: fieldPath
                )
            }
        }

        return FlowResolvedRunPath(absolutePath: absolutePath, irPath: irPath)
    }

    static func resolveIRRunPath(irRun: String, sourcePath: String) -> String {
        if irRun.hasPrefix("/") {
            return URL(fileURLWithPath: irRun).standardizedFileURL.path
        }
        if irRun.hasPrefix("~/") {
            let expanded = NSString(string: irRun).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }

        let flowDir = URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
        return URL(fileURLWithPath: irRun, relativeTo: flowDir).standardizedFileURL.path
    }

    private static func relativePath(from basePath: String, to targetPath: String) -> String {
        let baseComponents = URL(fileURLWithPath: basePath).standardizedFileURL.pathComponents
        let targetComponents = URL(fileURLWithPath: targetPath).standardizedFileURL.pathComponents

        var index = 0
        while index < baseComponents.count,
              index < targetComponents.count,
              baseComponents[index] == targetComponents[index] {
            index += 1
        }

        var parts: [String] = []
        if index < baseComponents.count {
            for _ in index..<(baseComponents.count) {
                parts.append("..")
            }
        }
        if index < targetComponents.count {
            parts.append(contentsOf: targetComponents[index...])
        }

        if parts.isEmpty {
            return "."
        }
        return parts.joined(separator: "/")
    }
}
