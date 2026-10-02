import Foundation
import ZeddyCore
import SwiftUI

/// One row from the daemon's `list` response (mirrors `Memory`, trimmed for the grid).
struct MemoryRow: Identifiable, Codable, Sendable {
    let id: String
    let kind: String
    let title: String
    let projectPath: String?
    let tags: [String]
    let createdAt: Double   // epoch seconds
    let lastUsedAt: Double?
    let useCount: Int

    var date: Date { Date(timeIntervalSince1970: createdAt) }
    var memoryID: UUID { UUID(uuidString: id) ?? UUID() }
}

/// Observable application state for the Zeddy GUI.
///
/// Talks to the daemon over its socket. `DaemonClient.request` is a blocking
/// call, so every round-trip runs on a background `Task` and hops back to the
/// main actor to update published state.
@MainActor
final class ZeddyModel: ObservableObject {
    @Published var connected = false
    @Published var status: DaemonStatus?
    @Published var memories: [MemoryRow] = []
    @Published var selection: Memory.ID?
    @Published var detail: Memory?
    @Published var kindFilter: Memory.Kind?
    @Published var projectFilter: String?
    @Published var tagFilter: String?

    // Context preview
    @Published var previewPrompt: String = ""
    @Published var previewResult: BuildContextResult?
    @Published var previewRunning = false
    @Published var statusMessage: String?

    // Add/edit form
    @Published var showForm = false
    @Published var formMemory = Memory(kind: .note, title: "", content: "")
    @Published var formProjectText = ""
    @Published var formTagsText = ""
    @Published var formKind: Memory.Kind = .note
    @Published var editingID: UUID?

    private let client = DaemonClient()
    private var pollTask: Task<Void, Never>?

    // MARK: - Connection

    func connect() async {
        status = await Self.run { [client] in client.statusFrame() }
        connected = await Self.run { [client] in client.status() }
        statusMessage = connected ? nil : "Daemon not reachable (is it running?)"
        if connected {
            await refresh()
            startPolling()
        }
    }

    func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        connected = false
        status = nil
        memories = []
        detail = nil
    }

    // MARK: - Daemon lifecycle (for the Daemon pane)

    func startDaemon() {
        Task {
            let ok = await Self.run { [client] in
                if try? client.start() { return true }
                // Fall back to process-level start if the daemon isn't already up.
                return try? ZeddyCore.DaemonControl.start()
            }
            connected = await Self.run { [client] in client.status() }
            status = await Self.run { [client] in client.statusFrame() }
            statusMessage = connected ? (ok ? "daemon started" : nil) : nil
            if connected { await refresh() }
        }
    }

    func stopDaemon() {
        Task {
            _ = await Self.run { [client] in
                try? client.stop()
                return true
            }
            connected = await Self.run { [client] in client.status() }
            status = await Self.run { [client] in client.statusFrame() }
        }
    }

    // MARK: - Settings

    func saveSettings(_ new: ZeddySettings) {
        Task {
            let ok = await Self.run { [client] in
                client.request(.init(.setSettings(new))).ok
            }
            statusMessage = ok ? "Settings saved" : "Failed to save settings"
            status = await Self.run { [client] in client.statusFrame() }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 s
                guard let self else { return }
                let ok = await Self.run { [client] in client.status() }
                self.connected = ok
                self.status = await Self.run { [client] in client.statusFrame() }
            }
        }
    }

    // MARK: - CRUD

    func refresh() async {
        let rows = await Self.run { [client] in
            let f = client.request(.init(.list(ListPayload())))
            guard f.ok, let d = f.data else { return [] as [MemoryRow] }
            let data = (try? IPC.encoder.encode(d)) ?? Data()
            return (try? IPC.decoder.decode([MemoryRow].self, from: data)) ?? []
        }
        memories = rows
    }

    func addMemory() {
        editingID = nil
        formMemory = Memory(kind: .note, title: "", content: "")
        formProjectText = ""
        formTagsText = ""
        formKind = .note
        showForm = true
    }

    func editMemory(_ row: MemoryRow) {
        // Load full content for the form.
        Task {
            if let m = await Self.fetchDetail(id: row.memoryID, client: client) {
                self.editingID = m.id
                self.formMemory = m
                self.formProjectText = m.projectPath ?? ""
                self.formTagsText = m.tags.joined(separator: ", ")
                self.formKind = m.kind
                self.showForm = true
            }
        }
    }

    func submitForm() {
        let project = formProjectText.trimmingCharacters(in: .whitespaces)
        let tags = formTagsText
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var m = formMemory
        m.kind = formKind
        m.projectPath = project.isEmpty ? nil : project
        m.tags = tags

        Task {
            let ok = await Self.run { [client] in
                let f = client.request(.init(.remember(m)))
                return f.ok
            }
            if ok {
                statusMessage = "Saved “\(m.title)”"
                await refresh()
            } else {
                statusMessage = "Save failed"
            }
        }
        showForm = false
    }

    func deleteMemory(_ row: MemoryRow) {
        Task {
            let ok = await Self.run { [client] in
                client.request(.init(.delete(row.memoryID))).ok
            }
            if ok { await refresh() }
        }
    }

    func fetchDetail(id: UUID) -> Memory? {
        Self.fetchDetail(id: id, client: client)
    }

    private static func fetchDetail(id: UUID, client: DaemonClient) -> Memory? {
        let f = client.request(.init(.get(id)))
        guard f.ok, let d = f.data else { return nil }
        let data = (try? IPC.encoder.encode(d)) ?? Data()
        return try? IPC.decoder.decode(Memory.self, from: data)
    }

    // MARK: - Context preview

    func runPreview() {
        guard !previewPrompt.isEmpty else { return }
        previewRunning = true
        let project = projectFilter?.isEmpty == false ? projectFilter : nil
        Task {
            let result = await Self.run { [client] in
                var bc = BuildContextPayload(prompt: previewPrompt, projectPath: project)
                let f = client.request(.init(.buildContext(bc)))
                guard f.ok, let d = f.data else { return nil }
                let data = (try? IPC.encoder.encode(d)) ?? Data()
                return try? IPC.decoder.decode(BuildContextResult.self, from: data)
            }
            previewResult = result
            previewRunning = false
        }
    }

    // MARK: - Helpers

    var filteredMemories: [MemoryRow] {
        memories.filter { row in
            if let k = kindFilter, row.kind != k.rawValue { return false }
            if let p = projectFilter, row.projectPath != p { return false }
            if let t = tagFilter, !row.tags.contains(t) { return false }
            return true
        }
    }

    /// Run a blocking `DaemonClient` call on a background executor, return its
    /// `Sendable` result to the caller (main) actor.
    private static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }
}
