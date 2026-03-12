import Foundation

public struct FlowResolvedDefinitionPath: Sendable, Equatable {
    public var displayPath: String
    public var canonicalPath: String
    public var workspacePath: String
    public var suggestedName: String

    public init(
        displayPath: String,
        canonicalPath: String,
        workspacePath: String,
        suggestedName: String
    ) {
        self.displayPath = displayPath
        self.canonicalPath = canonicalPath
        self.workspacePath = workspacePath
        self.suggestedName = suggestedName
    }
}

enum FlowDefinitionPathResolver {
    static func resolve(
        rawPath: String,
        baseDirectory: String? = nil,
        requireFileExists: Bool = false
    ) throws -> FlowResolvedDefinitionPath {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FlowError(
                code: "flow.path.invalid_path_kind",
                message: "Flow path must not be empty",
                phase: .runtimePreflight
            )
        }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        let absolutePath: String
        if expanded.hasPrefix("/") {
            absolutePath = URL(fileURLWithPath: expanded).standardizedFileURL.path
        } else {
            let base = baseDirectory ?? FileManager.default.currentDirectoryPath
            absolutePath = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: base)).standardizedFileURL.path
        }

        let canonical = URL(fileURLWithPath: absolutePath).resolvingSymlinksInPath().standardizedFileURL.path
        if requireFileExists {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory)
            if !exists || isDirectory.boolValue {
                throw FlowError(
                    code: "flow.path.not_found",
                    message: "Flow file not found: \(canonical)",
                    phase: .runtimePreflight
                )
            }
        }

        let url = URL(fileURLWithPath: canonical)
        return FlowResolvedDefinitionPath(
            displayPath: trimmed,
            canonicalPath: canonical,
            workspacePath: url.deletingLastPathComponent().path,
            suggestedName: url.deletingPathExtension().lastPathComponent
        )
    }

    static func tryResolve(
        rawPath: String,
        baseDirectory: String? = nil
    ) -> FlowResolvedDefinitionPath? {
        try? resolve(rawPath: rawPath, baseDirectory: baseDirectory, requireFileExists: false)
    }
}
