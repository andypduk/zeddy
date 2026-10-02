import Foundation

/// Typed payloads for the Zeddy IPC protocol, plus `Frame` factory builders.
///
/// These live in `ZeddyCore` so both the `zeddy` CLI and the `zeddy-app` GUI
/// share one canonical way to build a request. Each builder funnels through
/// `JSONValue.encode`, and `Memory` self-encodes its dates as epoch doubles,
/// so the whole round-trip is lossless.

// MARK: - Payloads

/// Creates a new memory. Optional fields default to a fresh global memory.
public struct AddPayload: Codable, Sendable {
    public var id: UUID?
    public var kind: Memory.Kind?
    public var title: String?
    public var content: String?
    public var projectPath: String?
    public var tags: [String]?

    public init(
        id: UUID? = nil,
        kind: Memory.Kind? = nil,
        title: String? = nil,
        content: String? = nil,
        projectPath: String? = nil,
        tags: [String]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
        self.projectPath = projectPath
        self.tags = tags
    }

    /// Fill in server-authoritative defaults the client need not supply.
    public func toMemory() -> Memory {
        Memory(
            id: id ?? UUID(),
            kind: kind ?? .global,
            title: title ?? "",
            content: content ?? "",
            projectPath: projectPath,
            tags: tags ?? [],
            createdAt: .now,
            lastUsedAt: nil,
            useCount: 0
        )
    }
}

/// Modifies an existing memory. Only non-`nil` fields are applied, so a client
/// can update a single field without resending the whole memory.
public struct UpdatePayload: Codable, Sendable {
    public var id: String
    public var kind: Memory.Kind?
    public var title: String?
    public var content: String?
    public var projectPath: String?
    public var tags: [String]?

    public init(
        id: String,
        kind: Memory.Kind? = nil,
        title: String? = nil,
        content: String? = nil,
        projectPath: String? = nil,
        tags: [String]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
        self.projectPath = projectPath
        self.tags = tags
    }
}

/// A relevance search. An empty/whitespace-only `text` returns no hits.
public struct SearchPayload: Codable, Sendable {
    public var text: String
    public var kind: Memory.Kind?
    public var projectPath: String?
    public var limit: Int?

    public init(
        text: String,
        kind: Memory.Kind? = nil,
        projectPath: String? = nil,
        limit: Int? = nil
    ) {
        self.text = text
        self.kind = kind
        self.projectPath = projectPath
        self.limit = limit
    }
}

/// A filtered listing (no free-text query).
public struct ListPayload: Codable, Sendable {
    public var kind: Memory.Kind?
    public var projectPath: String?

    public init(kind: Memory.Kind? = nil, projectPath: String? = nil) {
        self.kind = kind
        self.projectPath = projectPath
    }
}

/// Builds the token-budget context block for a prompt.
public struct BuildContextPayload: Codable, Sendable {
    public var prompt: String
    public var projectPath: String?

    public init(prompt: String, projectPath: String? = nil) {
        self.prompt = prompt
        self.projectPath = projectPath
    }
}

/// Prunes memories unused for `days` days (default 90).
public struct PrunePayload: Codable, Sendable {
    public var days: Int?

    public init(days: Int? = nil) { self.days = days }
}

// MARK: - Frame factories

extension IPC.Frame {
    /// A fresh request id. Callers can mutate this if they want to batch many
    /// requests on one connection (the daemon answers each by its own id).
    private static func request(_ method: String, params: [String: JSONValue]) -> IPC.Frame {
        IPC.Frame(method: method, id: 0, params: params)
    }

    public static func version() -> IPC.Frame { request("version", params: [:]) }

    public static func status() -> IPC.Frame { request("status", params: [:]) }

    public static func stats() -> IPC.Frame { request("stats", params: [:]) }

    public static func add(_ payload: AddPayload) -> IPC.Frame {
        request("add", params: JSONValue.encode(payload).objectValue ?? [:])
    }

    /// Convenience: build an `add` from plain values.
    public static func add(
        title: String,
        content: String,
        kind: Memory.Kind? = nil,
        projectPath: String? = nil,
        tags: [String] = []
    ) -> IPC.Frame {
        add(AddPayload(
            kind: kind, title: title, content: content,
            projectPath: projectPath, tags: tags
        ))
    }

    public static func update(_ payload: UpdatePayload) -> IPC.Frame {
        request("update", params: JSONValue.encode(payload).objectValue ?? [:])
    }

    public static func update(
        id: String,
        kind: Memory.Kind? = nil,
        title: String? = nil,
        content: String? = nil,
        projectPath: String? = nil,
        tags: [String]? = nil
    ) -> IPC.Frame {
        update(UpdatePayload(
            id: id, kind: kind, title: title, content: content,
            projectPath: projectPath, tags: tags
        ))
    }

    public static func get(id: String) -> IPC.Frame {
        request("get", params: ["id": .string(id)])
    }

    public static func delete(id: String) -> IPC.Frame {
        request("delete", params: ["id": .string(id)])
    }

    public static func search(_ payload: SearchPayload) -> IPC.Frame {
        request("search", params: JSONValue.encode(payload).objectValue ?? [:])
    }

    public static func search(
        _ text: String,
        kind: Memory.Kind? = nil,
        projectPath: String? = nil,
        limit: Int? = nil
    ) -> IPC.Frame {
        search(SearchPayload(text: text, kind: kind, projectPath: projectPath, limit: limit))
    }

    public static func list(_ payload: ListPayload) -> IPC.Frame {
        request("list", params: JSONValue.encode(payload).objectValue ?? [:])
    }

    public static func list(
        kind: Memory.Kind? = nil,
        projectPath: String? = nil
    ) -> IPC.Frame {
        list(ListPayload(kind: kind, projectPath: projectPath))
    }

    public static func buildContext(_ payload: BuildContextPayload) -> IPC.Frame {
        request("build_context", params: JSONValue.encode(payload).objectValue ?? [:])
    }

    public static func buildContext(prompt: String, projectPath: String? = nil) -> IPC.Frame {
        buildContext(BuildContextPayload(prompt: prompt, projectPath: projectPath))
    }

    public static func prune(_ days: Int? = nil) -> IPC.Frame {
        request("prune", params: JSONValue.encode(PrunePayload(days: days)).objectValue ?? [:])
    }

    public static func getSettings() -> IPC.Frame {
        request("settings", params: [:])
    }

    public static func updateSettings(_ settings: ZeddySettings) -> IPC.Frame {
        request("update_settings", params: JSONValue.encode(settings).objectValue ?? [:])
    }

    /// `data` is base64; the daemon returns the number of imported memories.
    public static func `import`(base64: String) -> IPC.Frame {
        request("import", params: ["data": .string(base64)])
    }

    /// Returns the exported store as a base64 string.
    public static func export() -> IPC.Frame {
        request("export", params: [:])
    }

    public static func usageStats(period: String = "live") -> IPC.Frame {
        request("usage_stats", params: ["period": .string(period)])
    }

    public static func usageLogs(limit: Int = 50) -> IPC.Frame {
        request("usage_logs", params: ["limit": .int(limit)])
    }

    public static func usageClear() -> IPC.Frame {
        request("usage_clear", params: [:])
    }
}
