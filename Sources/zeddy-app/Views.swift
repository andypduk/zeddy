import SwiftUI
import ZeddyCore

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: ZeddyModel

    enum Section: Hashable, CaseIterable, Identifiable {
        case memories, preview, settings, daemon
        var id: Self { self }
        var label: String {
            switch self {
            case .memories: return "Memories"
            case .preview: return "Context Preview"
            case .settings: return "Settings"
            case .daemon: return "Daemon"
            }
        }
        var icon: String {
            switch self {
            case .memories: return "memorychip"
            case .preview: return "text.bubble"
            case .settings: return "gearshape"
            case .daemon: return "antenna.radiowaves.left.and.right"
            }
        }
    }

    @State private var section: Section? = .memories

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.label, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 280)
            .navigationTitle("Zeddy")
        } content: {
            Group {
                switch section {
                case .memories, .none: MemoriesView()
                case .preview: ContextPreviewView()
                case .settings: SettingsView()
                case .daemon: DaemonView()
                }
            }
            .frame(minWidth: 680, minHeight: 480)
        }
        .overlay(alignment: .bottom) { statusFooter }
        .onAppear { if !model.connected { Task { await model.connect() } } }
    }

    @ViewBuilder
    private var statusFooter: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.connected ? Color.green : Color.red)
                .frame(width: 9, height: 9)
            if model.connected {
                if let s = model.status {
                    Text("\(s.store.total) memories")
                    if let st = model.statusMessage { Text("· " + st) }
                }
            } else {
                Text("Daemon not connected")
                Button("Connect") { Task { await model.connect() } }
                    .buttonStyle(.borderless)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

// MARK: - Memories (list + detail)

struct MemoriesView: View {
    @EnvironmentObject var model: ZeddyModel
    @State private var selectedID: String?
    @State private var search = ""

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 300, idealWidth: 360)
            detailPane
                .frame(minWidth: 320)
        }
        .sheet(isPresented: $model.showForm) { MemoryFormSheet() }
    }

    private var filtered: [MemoryRow] {
        model.filteredMemories.filter {
            if search.isEmpty { return true }
            let s = search.lowercased()
            return $0.title.lowercased().contains(s)
                || ($0.projectPath?.lowercased().contains(s) ?? false)
                || $0.tags.contains { $0.lowercased().contains(s) }
        }
    }

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Filter…", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button { model.addMemory() } label: { Image(systemName: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New memory")
            }
            List(filtered, selection: $selectedID) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.headline).lineLimit(1)
                    HStack {
                        Text(row.kind).foregroundStyle(.secondary)
                        if let p = row.projectPath {
                            Text(p).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if row.useCount > 0 {
                            Text("used ×\(row.useCount)").foregroundStyle(.tertiary)
                        }
                    }.font(.caption)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            .onChange(of: selectedID) { _, newID in
                if let newID, let row = filtered.first(where: { $0.id == newID }) {
                    Task { model.detail = await model.fetchDetail(id: row.memoryID) }
                } else {
                    model.detail = nil
                }
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let row = filtered.first(where: { $0.id == selectedID }) {
            MemoryDetailView(row: row, detail: model.detail)
        } else {
            VStack {
                Spacer()
                Image(systemName: "memorychip").font(.system(size: 42)).foregroundStyle(.tertiary)
                Text("Select a memory").font(.title3).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct MemoryDetailView: View {
    @EnvironmentObject var model: ZeddyModel
    let row: MemoryRow
    let detail: Memory?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(row.title).font(.title2).bold()
                HStack(spacing: 6) {
                    TagBadge(text: row.kind, color: .blue)
                    if !row.tags.isEmpty {
                        ForEach(row.tags, id: \.self) { TagBadge(text: $0, color: .purple) }
                    }
                    if let p = row.projectPath {
                        TagBadge(text: p, color: .orange)
                    }
                }
                Divider()
                if let d = detail {
                    Text(d.content)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Loading…").foregroundStyle(.secondary)
                }
                Divider()
                HStack(spacing: 16) {
                    Text("Created \(formatted(row.date))").foregroundStyle(.secondary)
                    if let lu = row.lastUsedAt {
                        Text("Used \(formatted(Date(timeIntervalSince1970: lu)))").foregroundStyle(.secondary)
                    }
                    Spacer()
                }.font(.caption)
            }
            .padding(18)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.editMemory(row) } label: { Label("Edit", systemImage: "pencil") }
                    .disabled(model.detail == nil)
                Button(role: .destructive) { model.deleteMemory(row) } label: { Label("Delete", systemImage: "trash") }
                    .disabled(model.detail == nil)
            }
        }
    }

    private func formatted(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}

struct TagBadge: View {
    let text: String
    var color: Color = .accentColor
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Add / Edit form

struct MemoryFormSheet: View {
    @EnvironmentObject var model: ZeddyModel
    @Environment(\.dismiss) private var dismiss

    private var kindNames: [(Memory.Kind, String)] {
        [(.note, "Note"), (.convention, "Convention"), (.decision, "Decision"), (.preference, "Preference")]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.editingID == nil ? "New Memory" : "Edit Memory").font(.title3).bold()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)

            Divider()

            Form {
                Picker("Kind", selection: $model.formKind) {
                    ForEach(kindNames, id: \.0) { k, name in Text(name).tag(k) }
                }.pickerStyle(.segmented)

                TextField("Title", text: $model.formMemory.title)
                TextField("Project path (empty = global)", text: $model.formProjectText)
                TextField("Tags (comma-separated)", text: $model.formTagsText)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Content")
                    TextEditor(text: $model.formMemory.content)
                        .font(.body.monospaced())
                        .frame(minHeight: 160)
                        .overlay(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 4).stroke(.quaternary)
                        }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let id = model.editingID {
                    Text("id: \(id)").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Save") { model.submitForm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.formMemory.title.isEmpty)
            }.padding(14)
        }
        .frame(width: 520)
    }
}

// MARK: - Context Preview

struct ContextPreviewView: View {
    @EnvironmentObject var model: ZeddyModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Type a prompt to preview injected context…", text: $model.previewPrompt)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.runPreview() }
                Button {
                    model.runPreview()
                } label: {
                    if model.previewRunning { ProgressView() } else { Image(systemName: "play.fill") }
                }
                .disabled(model.previewRunning || model.previewPrompt.isEmpty)
            }

            if let r = model.previewResult {
                HStack(spacing: 14) {
                    StatCard(label: "Memories", value: "\(r.selectedCount)")
                    StatCard(label: "Tokens", value: "\(r.estimatedTokens)")
                    StatCard(label: "Truncated", value: r.truncated ? "yes" : "no")
                    Spacer()
                }

                ScrollView {
                    Text(r.context)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "text.bubble").font(.system(size: 38)).foregroundStyle(.tertiary)
                    Text("Run a preview to see the compact context Zeddy would inject.")
                        .foregroundStyle(.secondary)
                }.frame(maxHeight: .infinity)
            }
        }
        .padding(16)
    }
}

struct StatCard: View {
    let label: String
    let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 90)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: ZeddyModel
    @State private var s = ZeddySettings.default

    var body: some View {
        Form {
            Section("Context budget") {
                Stepper("Max memories: \(s.maxMemories)", value: $s.maxMemories, in: 1...200)
                Stepper("Max tokens: \(s.maxTokens)", value: $s.maxTokens, in: 0...200_000, step: 250)
                Stepper("Top memory tokens: \(s.topMemoryTokens)", value: $s.topMemoryTokens, in: 1...5_000)
            }
            Section("Relevance") {
                Slider(value: $s.minScore, in: 0...1, step: 0.05) {
                    Text("Min relevance score")
                }
                LabeledContent("Min score: \(s.minScore, specifier: "%.2f")")
            }
            Section("Inclusion") {
                Toggle("Include project memories", isOn: $s.includeProject)
                Toggle("Include global memories", isOn: $s.includeGlobal)
            }
            Section("Maintenance") {
                Stepper("Prune after: \(s.pruneAfterDays) days", value: $s.pruneAfterDays, in: 0...3650)
                    .disabled(s.pruneAfterDays == 0)
            }
        }
        .formStyle(.grouped)
        .padding(10)
        .safeAreaInset(edge: .bottom) {
            HStack {
                if let st = model.status {
                    Text("Currently saved: maxTokens \(st.settings.maxTokens), maxMemories \(st.settings.maxMemories)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Apply & Save") { save() }.keyboardShortcut(.defaultAction)
            }.padding(12)
        }
    }

    private func save() {
        model.saveSettings(s)
    }
}

// MARK: - Daemon

struct DaemonView: View {
    @EnvironmentObject var model: ZeddyModel

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Connected", value: model.connected ? "yes" : "no")
                if let s = model.status {
                    LabeledContent("Socket", value: s.socketPath)
                    LabeledContent("Store", value: s.store.databasePath)
                    LabeledContent("Memories", value: "\(s.store.total)")
                    LabeledContent("SQLite", value: s.store.libraryVersion)
                    LabeledContent("Uptime", value: String(format: "%.0f s", s.uptimeSeconds))
                } else if model.connected {
                    LabeledContent("Status", value: "unavailable")
                }
            }
            Section {
                HStack {
                    Button("Start Daemon") { model.startDaemon() }
                    Button("Stop Daemon") { model.stopDaemon() }
                    Spacer()
                    Button("Refresh") { Task { await model.refresh() } }
                }
            }
        }
        .formStyle(.grouped)
        .padding(10)
    }
}
