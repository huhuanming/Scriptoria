import Foundation

public enum AgentRuntimeCatalog {
    public static let defaultModel = "gpt-5.3-codex"

    public enum Provider: String, CaseIterable, Sendable {
        case codex
        case claude
        case kimi
        case custom

        public var displayName: String {
            switch self {
            case .codex:
                return "codex"
            case .claude:
                return "claude"
            case .kimi:
                return "kimi"
            case .custom:
                return "custom"
            }
        }

        public var defaultModel: String? {
            switch self {
            case .codex:
                return AgentRuntimeCatalog.defaultModel
            case .claude:
                return "claude-sonnet"
            case .kimi:
                return "kimi-k2"
            case .custom:
                return nil
            }
        }
    }

    public struct ProviderAvailability: Sendable, Equatable, Identifiable {
        public let provider: Provider
        public let executable: String
        public let resolvedPath: String?
        public let source: String

        public init(
            provider: Provider,
            executable: String,
            resolvedPath: String?,
            source: String
        ) {
            self.provider = provider
            self.executable = executable
            self.resolvedPath = resolvedPath
            self.source = source
        }

        public var id: String {
            "\(provider.rawValue):\(executable)"
        }

        public var isAvailable: Bool {
            resolvedPath != nil
        }
    }

    public struct Snapshot: Sendable, Equatable {
        public let configuredExecutable: String
        public let configuredProvider: Provider
        public let providers: [ProviderAvailability]
        public let models: [String]

        public init(
            configuredExecutable: String,
            configuredProvider: Provider,
            providers: [ProviderAvailability],
            models: [String]
        ) {
            self.configuredExecutable = configuredExecutable
            self.configuredProvider = configuredProvider
            self.providers = providers
            self.models = models
        }

        public var activeProvider: ProviderAvailability? {
            providers.first { $0.provider == configuredProvider }
        }
    }

    public static func normalizeModel(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    public static func detectProvider(forExecutable executable: String) -> Provider {
        let lower = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        if lower.contains("claude") {
            return .claude
        }
        if lower.contains("kimi") {
            return .kimi
        }
        if lower.contains("codex") {
            return .codex
        }
        return .custom
    }

    public static func provider(forModel model: String) -> Provider {
        let lower = model.lowercased()
        if lower.contains("claude") {
            return .claude
        }
        if lower.contains("kimi") {
            return .kimi
        }
        if lower.contains("gpt") || lower.contains("codex") {
            return .codex
        }
        return .custom
    }

    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> Snapshot {
        let configuredFromEnv = environment["SCRIPTORIA_CODEX_EXECUTABLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredExecutable = (configuredFromEnv?.isEmpty == false) ? configuredFromEnv! : "codex"
        let configuredProvider = detectProvider(forExecutable: configuredExecutable)

        var byProvider: [Provider: ProviderAvailability] = [:]
        byProvider[configuredProvider] = ProviderAvailability(
            provider: configuredProvider,
            executable: configuredExecutable,
            resolvedPath: resolveExecutable(
                configuredExecutable,
                environment: environment,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ),
            source: (configuredFromEnv?.isEmpty == false) ? "env:SCRIPTORIA_CODEX_EXECUTABLE" : "default"
        )

        let candidates: [(String, String)] = [
            ("codex", "PATH"),
            ("claude-adapter", "PATH"),
            ("kimi-adapter", "PATH"),
            ("claude", "PATH"),
            ("kimi", "PATH"),
            ("\(homeDirectory)/.scriptoria/agents/claude-adapter", "~/.scriptoria/agents"),
            ("\(homeDirectory)/.scriptoria/agents/kimi-adapter", "~/.scriptoria/agents"),
        ]

        for (executable, source) in candidates {
            let provider = detectProvider(forExecutable: executable)
            guard provider != .custom else { continue }
            guard let resolved = resolveExecutable(
                executable,
                environment: environment,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ) else {
                continue
            }

            let found = ProviderAvailability(
                provider: provider,
                executable: executable,
                resolvedPath: resolved,
                source: source
            )

            if let existing = byProvider[provider] {
                if !existing.isAvailable {
                    byProvider[provider] = found
                }
            } else {
                byProvider[provider] = found
            }
        }

        var orderedProviders: [ProviderAvailability] = []
        if let configured = byProvider.removeValue(forKey: configuredProvider) {
            orderedProviders.append(configured)
        }
        for provider in Provider.allCases where provider != configuredProvider {
            if let found = byProvider.removeValue(forKey: provider) {
                orderedProviders.append(found)
            }
        }
        if !byProvider.isEmpty {
            orderedProviders.append(contentsOf: byProvider.values.sorted { $0.provider.rawValue < $1.provider.rawValue })
        }

        var models: [String] = [defaultModel]
        func appendModel(_ model: String?) {
            guard let model else { return }
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !models.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                models.append(trimmed)
            }
        }

        appendModel(configuredProvider.defaultModel)
        for found in orderedProviders where found.isAvailable {
            appendModel(found.provider.defaultModel)
        }

        return Snapshot(
            configuredExecutable: configuredExecutable,
            configuredProvider: configuredProvider,
            providers: orderedProviders,
            models: models
        )
    }

    private static func resolveExecutable(
        _ executable: String,
        environment: [String: String],
        homeDirectory: String,
        fileManager: FileManager
    ) -> String? {
        let trimmed = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expanded = expandPath(trimmed, homeDirectory: homeDirectory)
        if expanded.contains("/") {
            return isExecutable(path: expanded, fileManager: fileManager) ? expanded : nil
        }

        var searchPaths: [String] = []
        if let rawPath = environment["PATH"], !rawPath.isEmpty {
            searchPaths.append(contentsOf: rawPath.split(separator: ":").map(String.init))
        }
        searchPaths.append(contentsOf: [
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ])

        var visited = Set<String>()
        for dir in searchPaths {
            let expandedDir = expandPath(dir, homeDirectory: homeDirectory)
            guard !expandedDir.isEmpty else { continue }
            if !visited.insert(expandedDir).inserted { continue }

            let candidate = URL(fileURLWithPath: expandedDir).appendingPathComponent(trimmed).path
            if isExecutable(path: candidate, fileManager: fileManager) {
                return candidate
            }
        }

        return nil
    }

    private static func expandPath(_ path: String, homeDirectory: String) -> String {
        if path.hasPrefix("~") {
            return NSString(string: path).expandingTildeInPath
        }
        if path.hasPrefix("/") {
            return path
        }
        return path
    }

    private static func isExecutable(path: String, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: path) && fileManager.isExecutableFile(atPath: path)
    }
}
