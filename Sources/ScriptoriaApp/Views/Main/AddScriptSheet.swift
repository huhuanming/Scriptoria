import SwiftUI
import ScriptoriaCore

/// Sheet for adding a new script
struct AddScriptSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState

    @State private var title = ""
    @State private var description = ""
    @State private var path = ""
    @State private var interpreter: Interpreter = .auto
    @State private var tagsInput = ""
    @State private var isFavorite = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Script")
                    .font(.headline)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            Form {
                TextField("Title", text: $title)
                TextField("Description", text: $description)

                HStack {
                    TextField("Script Path", text: $path)
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url {
                            path = url.path
                            if title.isEmpty {
                                title = url.deletingPathExtension().lastPathComponent
                            }
                        }
                    }
                }

                Picker("Interpreter", selection: $interpreter) {
                    ForEach(Interpreter.allCases, id: \.self) { interp in
                        Text(interp.rawValue).tag(interp)
                    }
                }

                TextField("Tags (comma-separated)", text: $tagsInput)

                Toggle("Favorite", isOn: $isFavorite)
            }
            .formStyle(.grouped)
            .padding(.horizontal, 4)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Add Script") {
                    Task {
                        let tags = tagsInput.split(separator: ",")
                            .map { String($0).trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }

                        let resolvedPath: String
                        if path.hasPrefix("~") {
                            resolvedPath = NSString(string: path).expandingTildeInPath
                        } else {
                            resolvedPath = path
                        }

                        let script = Script(
                            title: title,
                            description: description,
                            path: resolvedPath,
                            interpreter: interpreter,
                            tags: tags,
                            isFavorite: isFavorite
                        )
                        await appState.addScript(script)
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty || path.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 480, height: 420)
    }
}

/// Sheet for editing an existing script
struct EditScriptSheet: View {
    let script: Script
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState

    @State private var title: String
    @State private var description: String
    @State private var path: String
    @State private var interpreter: Interpreter
    @State private var tagsInput: String
    @State private var isFavorite: Bool

    init(script: Script, isPresented: Binding<Bool>) {
        self.script = script
        self._isPresented = isPresented
        self._title = State(initialValue: script.title)
        self._description = State(initialValue: script.description)
        self._path = State(initialValue: script.path)
        self._interpreter = State(initialValue: script.interpreter)
        self._tagsInput = State(initialValue: script.tags.joined(separator: ", "))
        self._isFavorite = State(initialValue: script.isFavorite)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Script")
                    .font(.headline)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            Form {
                TextField("Title", text: $title)
                TextField("Description", text: $description)

                HStack {
                    TextField("Script Path", text: $path)
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url {
                            path = url.path
                        }
                    }
                }

                Picker("Interpreter", selection: $interpreter) {
                    ForEach(Interpreter.allCases, id: \.self) { interp in
                        Text(interp.rawValue).tag(interp)
                    }
                }

                TextField("Tags (comma-separated)", text: $tagsInput)
                Toggle("Favorite", isOn: $isFavorite)
            }
            .formStyle(.grouped)
            .padding(.horizontal, 4)

            Divider()

            HStack {
                Spacer()
                Button("Save") {
                    Task {
                        let tags = tagsInput.split(separator: ",")
                            .map { String($0).trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }

                        var updated = script
                        updated.title = title
                        updated.description = description
                        updated.path = path
                        updated.interpreter = interpreter
                        updated.tags = tags
                        updated.isFavorite = isFavorite
                        await appState.updateScript(updated)
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.isEmpty || path.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 480, height: 420)
    }
}
