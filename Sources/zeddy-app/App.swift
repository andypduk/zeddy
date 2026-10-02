import SwiftUI
import ZeddyCore

@main
struct ZeddyApp: App {
    var body: some Scene {
        WindowGroup("Zeddy") { ContentView() }
            .defaultSize(width: 980, height: 650)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var memories: [Memory] = []
    @Published var selected: Memory?
    @Published var query = ""
    @Published var context = ""
    @Published var contextTokens = 0
    @Published var status = "Daemon not connected"
    @Published var settings = ZeddySettings.default
    @Published var showingEditor = false
    @Published var draft = Memory(title: "", content: "")

    private let client = DaemonClient()

    func start() {
        do {
            _ = try DaemonControl.start()
            status = "Daemon running"
            refresh()
        } catch { status = "\(error)" }
    }

    func refresh() {
        do {
            let response = try client.call("list")
            guard response.ok, let data = response.data else { status = response.error ?? "List failed"; return }
            memories = decode(data, as: [Memory].self) ?? []
            settings = currentSettings() ?? settings
            status = "\(memories.count) memories"
        } catch { status = "\(error)" }
    }

    func saveDraft() {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let method = memories.contains(where: { $0.id == draft.id }) ? "update" : "add"
        let payload: [String: JSONValue]
        if method == "add" {
            payload = JSONValue.encode(AddPayload(id: draft.id, kind: draft.kind, title: draft.title, content: draft.content, projectPath: draft.projectPath, tags: draft.tags)).objectValue ?? [:]
        } else {
            payload = JSONValue.encode(UpdatePayload(id: draft.id.uuidString, kind: draft.kind, title: draft.title, content: draft.content, projectPath: draft.projectPath, tags: draft.tags)).objectValue ?? [:]
        }
        do {
            let response = try client.call(method, payload)
            if response.ok { showingEditor = false; refresh() } else { status = response.error ?? "Save failed" }
        } catch { status = "\(error)" }
    }

    func delete(_ memory: Memory) {
        do {
            let response = try client.call("delete", ["id": .string(memory.id.uuidString)])
            if response.ok { if selected?.id == memory.id { selected = nil }; refresh() }
        } catch { status = "\(error)" }
    }

    func buildContext() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let response = try client.call("build_context", ["prompt": .string(query)])
            guard response.ok, let data = response.data, let block: ContextBlock = decode(data, as: ContextBlock.self) else { status = response.error ?? "Context build failed"; return }
            context = block.text
            contextTokens = block.usedTokens
            status = "Selected \(block.usedIds.count) memories within \(block.budgetTokens)-token budget"
        } catch { status = "\(error)" }
    }

    func updateSettings() {
        do {
            let response = try client.call("update_settings", JSONValue.encode(settings).objectValue ?? [:])
            status = response.ok ? "Settings saved" : response.error ?? "Settings failed"
        } catch { status = "\(error)" }
    }

    private func currentSettings() -> ZeddySettings? {
        guard let response = try? client.call("settings"), response.ok, let data = response.data else { return nil }
        return decode(data, as: ZeddySettings.self)
    }

    private func decode<T: Decodable>(_ value: JSONValue, as type: T.Type) -> T? {
        guard let data = try? IPC.encoder.encode(value) else { return nil }
        return try? IPC.decoder.decode(T.self, from: data)
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selected) {
                Section("Memories") {
                    ForEach(model.memories) { memory in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(memory.title).lineLimit(1)
                            Text(memory.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(memory)
                        .contextMenu { Button("Delete", role: .destructive) { model.delete(memory) } }
                    }
                }
            }
            .navigationTitle("Zeddy")
            .toolbar {
                Button { model.draft = Memory(title: "", content: ""); model.showingEditor = true } label: { Label("New memory", systemImage: "plus") }
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        } detail: {
            TabView {
                memoryTab.tabItem { Label("Memory", systemImage: "brain") }
                contextTab.tabItem { Label("Context", systemImage: "text.badge.checkmark") }
                settingsTab.tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) { Text(model.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 6).background(.bar) }
        .task { model.start() }
        .sheet(isPresented: $model.showingEditor) { EditorView(model: model) }
        .onChange(of: model.selected) { memory in if let memory { model.draft = memory } }
    }

    private var memoryTab: some View {
        Group {
            if let memory = model.selected {
                VStack(alignment: .leading, spacing: 12) {
                    Text(memory.title).font(.title2.bold())
                    Text(memory.kind.rawValue.capitalized).foregroundStyle(.secondary)
                    Divider()
                    ScrollView { Text(memory.content).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    HStack { Button("Edit") { model.draft = memory; model.showingEditor = true }; Spacer(); Button("Delete", role: .destructive) { model.delete(memory) } }
                }
            } else {
                VStack(spacing: 10) { Image(systemName: "brain").font(.largeTitle); Text("Select a memory").font(.title3); Text("Create or choose a memory to inspect it.").foregroundStyle(.secondary) }
            }
        }
    }

    private var contextTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Context Preview").font(.title2.bold())
            Text("Retrieve only the most relevant stored memories under the configured token budget.").foregroundStyle(.secondary)
            TextField("Prompt to enrich", text: $model.query, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
            Button("Build Context") { model.buildContext() }.disabled(model.query.isEmpty)
            Text("Estimated tokens: \(model.contextTokens)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.context).font(.body.monospaced()).border(.quaternary).frame(maxHeight: .infinity)
        }
    }

    private var settingsTab: some View {
        Form {
            Section("Token budget") {
                Stepper("Total tokens: \(model.settings.budget.totalTokens)", value: $model.settings.budget.totalTokens, in: 100...16_000, step: 100)
                HStack { Text("Project allocation"); Slider(value: $model.settings.budget.projectRatio, in: 0...1); Text(model.settings.budget.projectRatio, format: .percent.precision(.fractionLength(0))) }
            }
            Section("Retrieval") {
                HStack { Text("Minimum score"); TextField("Score", value: $model.settings.minScore, format: .number).textFieldStyle(.roundedBorder) }
            }
            Button("Save Settings") { model.updateSettings() }
            Section("Storage") { LabeledContent("Location", value: Paths.base.path); LabeledContent("Socket", value: Paths.daemonSocketPath) }
        }
    }
}

private struct EditorView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var tags = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Memory").font(.title2.bold())
            TextField("Title", text: $model.draft.title)
            Picker("Scope", selection: $model.draft.kind) { Text("Global").tag(Memory.Kind.global); Text("Project").tag(Memory.Kind.project) }.pickerStyle(.segmented)
            TextField("Project path (project scope)", text: Binding(get: { model.draft.projectPath ?? "" }, set: { model.draft.projectPath = $0.isEmpty ? nil : $0 }))
            TextField("Tags, comma separated", text: $tags)
            TextEditor(text: $model.draft.content).border(.quaternary)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { model.draft.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }; model.saveDraft() }.keyboardShortcut(.defaultAction) }
        }
        .padding().frame(minWidth: 520, minHeight: 440)
        .onAppear { tags = model.draft.tags.joined(separator: ", ") }
    }
}
