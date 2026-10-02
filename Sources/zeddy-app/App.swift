import SwiftUI
import ZeddyCore

@main
struct ZeddyApp: App {
    @StateObject private var model = AppModel()

    init() {
        try? Paths.ensureLayout()
        if let icon = ZeddyIconView.loadNSImage() {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup("Zeddy") {
            ContentView(model: model)
        }
        .defaultSize(width: 1040, height: 700)

        Settings {
            SettingsView(model: model)
                .frame(width: 520, height: 560)
        }

        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.isDaemonRunning ? "bolt.fill" : "bolt.slash")
                Text("Zeddy")
            }
        }
        .menuBarExtraStyle(.window)
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

    // Throughput & Usage Dashboard State (9Router Style)
    @Published var usageStats = UsageStats()
    @Published var usageLogs: [UsageEvent] = []
    @Published var selectedEvent: UsageEvent?
    @Published var usagePeriod = "live"
    @Published var selectedTab = 0
    @Published var isDaemonRunning = DaemonControl.isRunning()

    private let client = DaemonClient()
    private var pollingTask: Task<Void, Never>?

    func start() {
        do {
            _ = try DaemonControl.start()
            isDaemonRunning = true
            status = "Daemon running"
            refresh()
            startUsagePolling()
        } catch { status = "\(error)" }
    }

    func stopDaemon() {
        do {
            try DaemonControl.stop()
            isDaemonRunning = false
            status = "Daemon stopped"
        } catch { status = "\(error)" }
    }

    func restartDaemon() {
        try? DaemonControl.stop()
        usleep(150_000)
        start()
    }

    func checkDaemonStatus() {
        isDaemonRunning = DaemonControl.isRunning()
    }

    func startUsagePolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.fetchUsage()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }

    func fetchUsage() {
        checkDaemonStatus()
        guard isDaemonRunning else { return }
        do {
            let sRes = try client.call("usage_stats", ["period": .string(usagePeriod)])
            if sRes.ok, let sData = sRes.data, let s: UsageStats = decode(sData, as: UsageStats.self) {
                self.usageStats = s
            }
            let lRes = try client.call("usage_logs", ["limit": .int(60)])
            if lRes.ok, let lData = lRes.data, let l: [UsageEvent] = decode(lData, as: [UsageEvent].self) {
                self.usageLogs = l
            }
        } catch {}
    }

    func clearUsage() {
        _ = try? client.call("usage_clear")
        fetchUsage()
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
    @ObservedObject var model: AppModel

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
                ToolbarItem(placement: .navigation) {
                    ZeddyIconView(size: 24)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.draft = Memory(title: "", content: ""); model.showingEditor = true } label: { Label("New memory", systemImage: "plus") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
            }
        } detail: {
            TabView(selection: $model.selectedTab) {
                UsageDashboardView(model: model)
                    .tabItem { Label("Throughput", systemImage: "gauge.with.dots.needle.bottom.50percent") }
                    .tag(0)
                memoryTab
                    .tabItem { Label("Memory", systemImage: "brain") }
                    .tag(1)
                contextTab
                    .tabItem { Label("Context", systemImage: "text.badge.checkmark") }
                    .tag(2)
                settingsTab
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(3)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) { Text(model.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 6).background(.bar) }
        .task { model.start() }
        .sheet(isPresented: $model.showingEditor) { EditorView(model: model) }
        .sheet(item: $model.selectedEvent) { event in RequestDetailSheet(event: event) }
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
                VStack(spacing: 14) {
                    ZeddyIconView(size: 80)
                    Text("Select a memory").font(.title3.bold())
                    Text("Create or choose a memory to inspect or edit.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        SettingsView(model: model)
    }
}

// MARK: - 9Router Style Usage & Throughput Dashboard

struct UsageDashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            // Header Bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Active Throughput & Usage")
                        .font(.title2.bold())
                    Text("Real-time token economy, prompt cache compression, and latency")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Period", selection: $model.usagePeriod) {
                    Text("Live (60s)").tag("live")
                    Text("Today").tag("today")
                    Text("All Time").tag("all")
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                .onChange(of: model.usagePeriod) { _ in
                    model.fetchUsage()
                }

                Button {
                    model.fetchUsage()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh metrics")

                Button(role: .destructive) {
                    model.clearUsage()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear metrics history")
            }

            // Top KPI Summary Cards (9Router Style)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                KPICard(
                    title: "Total Requests",
                    value: "\(model.usageStats.totalRequests)",
                    subtitle: "All operations",
                    icon: "arrow.triangle.2.circlepath",
                    color: .blue
                )
                KPICard(
                    title: "Injected Tokens",
                    value: formatTokens(model.usageStats.totalInjectedTokens),
                    subtitle: "Context in prompt",
                    icon: "text.badge.plus",
                    color: .purple
                )
                KPICard(
                    title: "Tokens Saved",
                    value: formatTokens(model.usageStats.totalSavedTokens),
                    subtitle: "Token Saver active",
                    icon: "leaf.fill",
                    color: .green,
                    badge: "SAVED"
                )
                KPICard(
                    title: "Average Latency",
                    value: String(format: "%.1f ms", model.usageStats.averageLatencyMs),
                    subtitle: "BM25 retrieval",
                    icon: "bolt.fill",
                    color: .orange
                )
                KPICard(
                    title: "Active Throughput",
                    value: String(format: "%.1f req/s", model.usageStats.requestsPerSec),
                    subtitle: "\(formatTokens(Int(model.usageStats.tokensPerSec))) tok/s",
                    icon: "speedometer",
                    color: .cyan,
                    isLive: model.usageStats.requestsPerSec > 0
                )
            }

            // Real-Time Activity / Histogram (9Router-style live chart)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Throughput Activity Timeline (Tokens & Reqs)", systemImage: "chart.bar.xaxis")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("15 sliding windows • 4s intervals")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                ThroughputHistogramView(buckets: model.usageStats.liveBuckets)
                    .frame(height: 64)
                    .padding(.vertical, 2)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))

            // Live Request Stream Table
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Live Request Stream", systemImage: "list.bullet.rectangle.portrait")
                        .font(.headline)
                    Spacer()
                    Text("\(model.usageLogs.count) recent calls")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.usageLogs.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("No requests captured yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Send prompt requests from Zed or run zeddy build-context to see live throughput")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(model.usageLogs, selection: Binding(
                        get: { model.selectedEvent?.id },
                        set: { newId in model.selectedEvent = model.usageLogs.first(where: { $0.id == newId }) }
                    )) {
                        TableColumn("Time") { event in
                            Text(formatTime(event.timestamp))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .width(min: 75, ideal: 85, max: 95)

                        TableColumn("Operation") { event in
                            OperationBadge(method: event.method)
                        }
                        .width(min: 100, ideal: 110, max: 130)

                        TableColumn("Prompt / Query Snippet") { event in
                            Text(event.promptSnippet.isEmpty ? "—" : event.promptSnippet)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                        }

                        TableColumn("Injected") { event in
                            Text("\(event.injectedTokens) tok")
                                .font(.caption.monospaced())
                                .foregroundStyle(event.injectedTokens > 0 ? .primary : .secondary)
                        }
                        .width(min: 70, ideal: 80, max: 95)

                        TableColumn("Saved") { event in
                            Text(event.estimatedSavedTokens > 0 ? "+\(event.estimatedSavedTokens) tok" : "—")
                                .font(.caption.monospaced())
                                .foregroundStyle(event.estimatedSavedTokens > 0 ? .green : .secondary)
                        }
                        .width(min: 70, ideal: 80, max: 95)

                        TableColumn("Latency") { event in
                            Text(String(format: "%.1f ms", event.durationMs))
                                .font(.caption.monospaced())
                        }
                        .width(min: 60, ideal: 70, max: 80)

                        TableColumn("Status") { event in
                            StatusBadge(status: event.status)
                        }
                        .width(min: 65, ideal: 75, max: 85)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding()
    }
}

struct KPICard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color
    var badge: String? = nil
    var isLive: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isLive {
                    Circle()
                        .fill(.green)
                        .frame(width: 7, height: 7)
                }
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                }
            }
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

struct ThroughputHistogramView: View {
    let buckets: [ThroughputBucket]

    var body: some View {
        let maxCount = max(1, buckets.map(\.tokenCount).max() ?? 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(buckets) { bucket in
                VStack(spacing: 2) {
                    GeometryReader { geo in
                        VStack {
                            Spacer()
                            let ratio = CGFloat(bucket.tokenCount) / CGFloat(maxCount)
                            let barHeight = bucket.tokenCount > 0 ? max(6, geo.size.height * ratio) : (bucket.requestCount > 0 ? 8 : 2)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(
                                    bucket.tokenCount > 0
                                    ? LinearGradient(colors: [.cyan, .purple], startPoint: .bottom, endPoint: .top)
                                    : (bucket.requestCount > 0 ? LinearGradient(colors: [.blue, .cyan], startPoint: .bottom, endPoint: .top) : LinearGradient(colors: [.secondary.opacity(0.2), .secondary.opacity(0.1)], startPoint: .bottom, endPoint: .top))
                                )
                                .frame(height: barHeight)
                        }
                    }
                    Text(bucket.tokenCount > 0 ? "\(bucket.tokenCount)" : (bucket.requestCount > 0 ? "•" : ""))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(height: 10)
                }
                .help("\(bucket.requestCount) requests, \(bucket.tokenCount) tokens")
            }
        }
    }
}

struct OperationBadge: View {
    let method: String

    var color: Color {
        switch method {
        case "build_context": return .purple
        case "search": return .cyan
        case "add": return .green
        case "update": return .orange
        case "delete": return .red
        default: return .blue
        }
    }

    var body: some View {
        Text(method)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct StatusBadge: View {
    let status: String

    var color: Color {
        switch status.lowercased() {
        case "hit", "success": return .green
        case "empty": return .secondary
        case "not_found", "error": return .red
        default: return .blue
        }
    }

    var body: some View {
        Text(status.uppercased())
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct RequestDetailSheet: View {
    let event: UsageEvent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                OperationBadge(method: event.method)
                Text("Request Details")
                    .font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Timestamp").foregroundStyle(.secondary)
                    Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                }
                GridRow {
                    Text("Duration").foregroundStyle(.secondary)
                    Text(String(format: "%.2f ms", event.durationMs))
                }
                GridRow {
                    Text("Status").foregroundStyle(.secondary)
                    StatusBadge(status: event.status)
                }
                GridRow {
                    Text("Tokens Injected").foregroundStyle(.secondary)
                    Text("\(event.injectedTokens) tokens (Budget: \(event.budgetTokens))")
                }
                GridRow {
                    Text("Tokens Saved").foregroundStyle(.secondary)
                    Text("+\(event.estimatedSavedTokens) tokens")
                        .foregroundStyle(.green)
                }
            }

            Divider()

            Text("Prompt / Query:")
                .font(.headline)
            ScrollView {
                Text(event.promptSnippet)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(maxHeight: 120)

            if !event.memoryTitles.isEmpty {
                Text("Injected Memories:")
                    .font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(event.memoryTitles, id: \.self) { title in
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                                Text(title)
                                    .font(.subheadline)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 540, minHeight: 460)
    }
}

private func formatTokens(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000.0)
    } else if count >= 1_000 {
        return String(format: "%.1fk", Double(count) / 1_000.0)
    } else {
        return "\(count)"
    }
}

private func formatTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: date)
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    ZeddyIconView(size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ZEDDY").font(.headline.bold())
                        Text("Ultra-fast local memory for Zed & 9Router").font(.subheadline).foregroundStyle(.secondary)
                        Text("SQLite FTS5 • BM25 Ranker • Model Context Protocol").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Token Budget & Allocation") {
                Stepper("Total budget: \(model.settings.budget.totalTokens) tokens", value: $model.settings.budget.totalTokens, in: 200...32_000, step: 100)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Project scope allocation:")
                        Spacer()
                        Text("\(Int(model.settings.budget.projectRatio * 100))% (\(model.settings.budget.projectTokens) tokens)")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.settings.budget.projectRatio, in: 0...1)
                }
                HStack {
                    Text("Global scope allocation:")
                    Spacer()
                    Text("\(100 - Int(model.settings.budget.projectRatio * 100))% (\(model.settings.budget.globalTokens) tokens)")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Relevance & Ranking Filter") {
                HStack {
                    Text("BM25 minimum score threshold:")
                    Spacer()
                    TextField("0.0", value: $model.settings.minScore, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                Text("Memories scoring below this threshold are omitted from prompt context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Background Indexing") {
                Stepper("Index refresh interval: \(Int(model.settings.indexRefreshInterval))s", value: $model.settings.indexRefreshInterval, in: 1...60, step: 1)
            }
            Section("Storage & Paths") {
                LabeledContent("Home Directory", value: Paths.base.path)
                LabeledContent("SQLite Database", value: Paths.dbFile)
                LabeledContent("Settings File", value: Paths.settingsFile)
                LabeledContent("IPC Socket", value: Paths.daemonSocketPath)
            }
            Section {
                HStack {
                    Button("Reset to Defaults", role: .destructive) {
                        model.settings = ZeddySettings.default
                        model.updateSettings()
                    }
                    Spacer()
                    Button("Save Settings") {
                        model.updateSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct EditorView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var tags = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZeddyIconView(size: 28)
                Text(model.memories.contains(where: { $0.id == model.draft.id }) ? "Edit Memory" : "New Memory").font(.title2.bold())
            }
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

// MARK: - Reusable Cyber Manga Icon View

struct ZeddyIconView: View {
    let size: CGFloat

    static func loadNSImage() -> NSImage? {
        let candidates = [
            Paths.logoSvgFile,
            "Assets/zeddy-logo-manga.svg",
            "../Assets/zeddy-logo-manga.svg",
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Assets/zeddy-logo-manga.svg").path
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path), let img = NSImage(contentsOfFile: path) {
                return img
            }
        }
        return nil
    }

    var body: some View {
        if let nsImage = Self.loadNSImage() {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.cyan.opacity(0.8), .purple.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: max(1, size * 0.03))
                )
                .shadow(color: .cyan.opacity(0.3), radius: size * 0.1, x: 0, y: size * 0.04)
        } else {
            // Native SwiftUI fallback cyber badge
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.08, green: 0.04, blue: 0.15), Color(red: 0.02, green: 0.01, blue: 0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("⚡Z")
                    .font(.system(size: size * 0.45, weight: .black, design: .monospaced))
                    .foregroundStyle(LinearGradient(colors: [.cyan, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .strokeBorder(Color.cyan.opacity(0.6), lineWidth: max(1, size * 0.03))
            )
        }
    }
}

// MARK: - Menu Bar View (Activity & Service Management)

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Status & Service Controls
            HStack(alignment: .center, spacing: 10) {
                ZeddyIconView(size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.isDaemonRunning ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(model.isDaemonRunning ? "Daemon Running" : "Daemon Stopped")
                            .font(.headline)
                    }
                    Text(model.isDaemonRunning ? "\(model.memories.count) memories indexed" : "Service offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isDaemonRunning {
                    Button(action: { model.restartDaemon() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Restart Daemon")

                    Button(action: { model.stopDaemon() }) {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Stop Daemon")
                } else {
                    Button(action: { model.start() }) {
                        Image(systemName: "play.fill")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                    .help("Start Daemon")
                }
            }
            .padding(.horizontal, 4)

            Divider()

            // 9Router-Style Live Metrics Snapshot
            VStack(alignment: .leading, spacing: 6) {
                Text("ACTIVITY & THROUGHPUT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    MenuBarMetricCard(
                        title: "REQ/S",
                        value: String(format: "%.1f", model.usageStats.requestsPerSec),
                        sub: "\(model.usageStats.totalRequests) total",
                        color: .cyan
                    )
                    MenuBarMetricCard(
                        title: "TOK/S",
                        value: String(format: "%.0f", model.usageStats.tokensPerSec),
                        sub: formatTokens(model.usageStats.totalInjectedTokens),
                        color: .purple
                    )
                    MenuBarMetricCard(
                        title: "SAVED",
                        value: formatTokens(model.usageStats.totalSavedTokens),
                        sub: "cached",
                        color: .green
                    )
                    MenuBarMetricCard(
                        title: "LATENCY",
                        value: String(format: "%.0fms", model.usageStats.averageLatencyMs),
                        sub: "avg",
                        color: .orange
                    )
                }
            }

            // Recent Activity Mini-List
            if !model.usageLogs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RECENT REQUESTS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 4) {
                        ForEach(model.usageLogs.prefix(3)) { event in
                            HStack(spacing: 6) {
                                OperationBadge(method: event.method)
                                Text(event.promptSnippet.isEmpty ? "—" : event.promptSnippet)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                                Text(String(format: "%.1fms", event.durationMs))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(6)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            // Quick Memory Viewer
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("INDEXED MEMORIES (\(model.memories.count))")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { model.refresh() }
                        .font(.caption2)
                        .buttonStyle(.plain)
                }

                if model.memories.isEmpty {
                    Text("No memories stored yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(model.memories.prefix(5)) { mem in
                                HStack(spacing: 6) {
                                    Image(systemName: mem.kind == .global ? "globe" : "folder")
                                        .font(.caption2)
                                        .foregroundStyle(mem.kind == .global ? .cyan : .purple)
                                    Text(mem.title)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(mem.content)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: 120, alignment: .trailing)
                                }
                                .padding(5)
                                .background(.quaternary.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                    .frame(maxHeight: 110)
                }
            }

            Divider()

            // Footer / Actions
            HStack {
                Button("Open Zeddy") {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.canBecomeMain {
                        window.makeKeyAndOrderFront(nil)
                        return
                    }
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear {
            model.checkDaemonStatus()
            model.fetchUsage()
        }
    }
}

private struct MenuBarMetricCard: View {
    let title: String
    let value: String
    let sub: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
            Text(sub)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
