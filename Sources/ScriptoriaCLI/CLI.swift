import ArgumentParser
import ScriptoriaCore

@main
struct ScriptoriaCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scriptoria",
        abstract: "Scriptoria — Your automation script workshop",
        version: "0.1.0",
        subcommands: [
            AddCommand.self,
            ListCommand.self,
            RunCommand.self,
            SearchCommand.self,
            RemoveCommand.self,
            TagsCommand.self,
            ScheduleCommand.self,
            ConfigCommand.self,
            MemoryCommand.self,
            PsCommand.self,
            LogsCommand.self,
            KillCommand.self,
            FlowCommand.self,
        ]
    )
}
