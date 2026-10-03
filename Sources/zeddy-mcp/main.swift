import Foundation
import ZeddyCore

// MARK: - JSON-RPC 2.0 / MCP Types

struct MCPRequest: Decodable {
    let jsonrpc: String?
    let id: JSONValue?
    let method: String
    let params: [String: JSONValue]?
}

struct MCPResponse: Encodable {
    let jsonrpc = "2.0"
    let id: JSONValue
    let result: JSONValue?
    let error: MCPError?

    init(id: JSONValue, result: JSONValue) {
        self.id = id
        self.result = result
        self.error = nil
    }

    init(id: JSONValue, error: MCPError) {
        self.id = id
        self.result = nil
        self.error = error
    }
}

struct MCPError: Encodable {
    let code: Int
    let message: String
    let data: JSONValue?

    init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    static func parseError(_ msg: String = "Parse error") -> MCPError {
        MCPError(code: -32700, message: msg)
    }
    static func invalidRequest(_ msg: String = "Invalid Request") -> MCPError {
        MCPError(code: -32600, message: msg)
    }
    static func methodNotFound(_ name: String) -> MCPError {
        MCPError(code: -32601, message: "Method not found: \(name)")
    }
    static func invalidParams(_ msg: String) -> MCPError {
        MCPError(code: -32602, message: msg)
    }
    static func internalError(_ msg: String) -> MCPError {
        MCPError(code: -32603, message: msg)
    }
}

// MARK: - MCP Tool Definitions

let mcpTools: [JSONValue] = [
    .object([
        "name": .string("zeddy_context"),
        "description": .string("Build token-budgeted, BM25-ranked relevant memory context for a user prompt or task in Zed/Cursor/Claude/cline."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "prompt": .object([
                    "type": .string("string"),
                    "description": .string("The user prompt or query to retrieve relevant memories for")
                ]),
                "projectPath": .object([
                    "type": .string("string"),
                    "description": .string("Optional path to project root for scoped memories")
                ])
            ]),
            "required": .array([.string("prompt")])
        ])
    ]),
    .object([
        "name": .string("zeddy_add"),
        "description": .string("Store a new persistent memory snippet (global or project scoped)."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object([
                    "type": .string("string"),
                    "description": .string("Title or summary of memory")
                ]),
                "content": .object([
                    "type": .string("string"),
                    "description": .string("Body content of the memory")
                ]),
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array([.string("global"), .string("project")]),
                    "description": .string("Scope: global or project")
                ]),
                "projectPath": .object([
                    "type": .string("string"),
                    "description": .string("Project path if kind is project")
                ]),
                "tags": .object([
                    "type": .array([.string("string")]),
                    "description": .string("Tags for categorization")
                ])
            ]),
            "required": .array([.string("title"), .string("content")])
        ])
    ]),
    .object([
        "name": .string("zeddy_search"),
        "description": .string("Search stored memories with SQLite BM25 full-text ranker."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Search query text or keywords")
                ]),
                "projectPath": .object([
                    "type": .string("string"),
                    "description": .string("Optional project path to filter search")
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum results (default 8)")
                ])
            ]),
            "required": .array([.string("query")])
        ])
    ]),
    .object([
        "name": .string("zeddy_list"),
        "description": .string("List all stored memories, optionally filtered by scope or project."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array([.string("global"), .string("project")]),
                    "description": .string("Filter by global or project scope")
                ]),
                "projectPath": .object([
                    "type": .string("string"),
                    "description": .string("Filter by project root path")
                ])
            ])
        ])
    ]),
    .object([
        "name": .string("zeddy_get"),
        "description": .string("Retrieve a single memory record by its UUID."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string("Memory UUID")
                ])
            ]),
            "required": .array([.string("id")])
        ])
    ]),
    .object([
        "name": .string("zeddy_delete"),
        "description": .string("Delete a memory record by UUID."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string("Memory UUID to remove")
                ])
            ]),
            "required": .array([.string("id")])
        ])
    ]),
    .object([
        "name": .string("zeddy_stats"),
        "description": .string("Get memory count, disk stats, and token budget configuration."),
        "inputSchema": .object([
            "type": .string("object")
        ])
    ])
]

// MARK: - Server Execution

final class MCPServer {
    private let client = DaemonClient()
    private var engine: Engine?

    init() {
        // Fallback in-process engine if daemon not currently running
        try? Paths.ensureLayout()
        if let store = try? MemoryStore(path: Paths.dbFile) {
            self.engine = Engine(store: store, settings: SettingsStore.load())
        }
    }

    private func sendResponse(_ response: MCPResponse) {
        if let data = try? IPC.encoder.encode(response) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
    }

    private func jsonString(from value: JSONValue) -> String {
        if let data = try? IPC.encoder.encode(value), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\(value)"
    }

    private func callZeddy(method: String, params: [String: JSONValue] = [:]) throws -> JSONValue {
        if client.isRunning {
            do {
                let res = try client.call(method, params)
                if !res.ok {
                    throw NSError(domain: "Zeddy", code: 1, userInfo: [NSLocalizedDescriptionKey: res.error ?? "daemon error"])
                }
                return res.data ?? .null
            } catch {
                if let engine {
                    let frame = IPC.Frame(method: method, params: params)
                    let res = engine.dispatch(frame)
                    if !res.ok {
                        throw NSError(domain: "Zeddy", code: 1, userInfo: [NSLocalizedDescriptionKey: res.error ?? "engine error"])
                    }
                    return res.data ?? .null
                }
                throw error
            }
        } else if let engine {
            let frame = IPC.Frame(method: method, params: params)
            let res = engine.dispatch(frame)
            if !res.ok {
                throw NSError(domain: "Zeddy", code: 1, userInfo: [NSLocalizedDescriptionKey: res.error ?? "engine error"])
            }
            return res.data ?? .null
        } else {
            throw NSError(domain: "Zeddy", code: 2, userInfo: [NSLocalizedDescriptionKey: "Zeddy daemon is not running and store unavailable"])
        }
    }

    func handleToolCall(name: String, arguments: [String: JSONValue]) throws -> JSONValue {
        switch name {
        case "zeddy_context":
            guard let prompt = arguments["prompt"]?.stringValue else {
                throw NSError(domain: "MCP", code: -32602, userInfo: [NSLocalizedDescriptionKey: "Missing 'prompt' argument"])
            }
            let project = arguments["projectPath"]?.stringValue
            let res = try callZeddy(method: "build_context", params: [
                "prompt": .string(prompt),
                "projectPath": project.map(JSONValue.string) ?? .null
            ])
            var text = ""
            var tokenCount = 0
            if let obj = res.objectValue {
                text = obj["text"]?.stringValue ?? ""
                tokenCount = obj["usedTokens"]?.intValue ?? 0
            } else if let str = res.stringValue {
                text = str
            }
            return .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(text.isEmpty ? "No relevant memories found within budget." : text)
                    ])
                ]),
                "meta": .object([
                    "usedTokens": .int(tokenCount)
                ])
            ])

        case "zeddy_add":
            guard let title = arguments["title"]?.stringValue,
                  let content = arguments["content"]?.stringValue else {
                throw NSError(domain: "MCP", code: -32602, userInfo: [NSLocalizedDescriptionKey: "Missing 'title' or 'content'"])
            }
            let kind = arguments["kind"]?.stringValue ?? "global"
            let project = arguments["projectPath"]?.stringValue
            let tags: [String]
            if case .array(let list) = arguments["tags"] {
                tags = list.compactMap { $0.stringValue }
            } else {
                tags = []
            }
            let payload = AddPayload(
                kind: Memory.Kind(rawValue: kind) ?? .global,
                title: title,
                content: content,
                projectPath: project,
                tags: tags
            )
            let res = try callZeddy(method: "add", params: JSONValue.encode(payload).objectValue ?? [:])
            return .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Memory stored successfully:\n\(jsonString(from: res))")
                    ])
                ])
            ])

        case "zeddy_search":
            guard let q = arguments["query"]?.stringValue else {
                throw NSError(domain: "MCP", code: -32602, userInfo: [NSLocalizedDescriptionKey: "Missing 'query'"])
            }
            let project = arguments["projectPath"]?.stringValue
            let limit = arguments["limit"]?.intValue ?? 8
            let res = try callZeddy(method: "search", params: [
                "q": .string(q),
                "projectPath": project.map(JSONValue.string) ?? .null,
                "limit": .int(limit)
            ])
            return .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(jsonString(from: res))
                    ])
                ])
            ])

        case "zeddy_list":
            let kind = arguments["kind"]?.stringValue
            let project = arguments["projectPath"]?.stringValue
            let res = try callZeddy(method: "list", params: [
                "kind": kind.map(JSONValue.string) ?? .null,
                "projectPath": project.map(JSONValue.string) ?? .null
            ])
            return .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(jsonString(from: res))
                    ])
                ])
            ])

        case "zeddy_get":
            guard let id = arguments["id"]?.stringValue else {
                throw NSError(domain: "MCP", code: -32602, userInfo: [NSLocalizedDescriptionKey: "Missing 'id'"])
            }
            let res = try callZeddy(method: "get", params: ["id": .string(id)])
            return .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(jsonString(from: res))
                    ])
                ])
            ])

        case "zeddy_delete":
            guard let id = arguments["id"]?.stringValue else {
                throw NSError(domain: "MCP", code: -32602, userInfo: [NSLocalizedDescriptionKey: "Missing 'id'"])
            }
            let res = try callZeddy(method: "delete", params: ["id": .string(id)])
            return .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Deleted: \(jsonString(from: res))")
                    ])
                ])
            ])

        case "zeddy_stats":
            let stats = try callZeddy(method: "stats")
            let settings = try callZeddy(method: "settings")
            return .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Stats:\n\(jsonString(from: stats))\n\nSettings:\n\(jsonString(from: settings))")
                    ])
                ])
            ])

        default:
            throw NSError(domain: "MCP", code: -32601, userInfo: [NSLocalizedDescriptionKey: "Unknown tool: \(name)"])
        }
    }

    func run() {
        let inputHandle = FileHandle.standardInput
        var lineBuffer = Data()

        while true {
            let chunk = inputHandle.availableData
            if chunk.isEmpty { break }
            lineBuffer.append(chunk)

            while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
                let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<newlineIndex)
                lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)

                guard !lineData.isEmpty else { continue }
                guard let req = try? IPC.decoder.decode(MCPRequest.self, from: lineData) else {
                    sendResponse(MCPResponse(id: .null, error: .parseError()))
                    continue
                }

                let reqId = req.id ?? .null

                switch req.method {
                case "initialize":
                    let initResult: JSONValue = .object([
                        "protocolVersion": .string("2024-11-05"),
                        "capabilities": .object([
                            "tools": .object([:])
                        ]),
                        "serverInfo": .object([
                            "name": .string("zeddy-mcp"),
                            "version": .string("1.0.0")
                        ])
                    ])
                    sendResponse(MCPResponse(id: reqId, result: initResult))

                case "notifications/initialized":
                    // MCP lifecycle notification, no response required
                    break

                case "ping":
                    sendResponse(MCPResponse(id: reqId, result: .object([:])))

                case "tools/list":
                    let toolsResult: JSONValue = .object([
                        "tools": .array(mcpTools)
                    ])
                    sendResponse(MCPResponse(id: reqId, result: toolsResult))

                case "tools/call":
                    let toolName = req.params?["name"]?.stringValue ?? ""
                    let toolArgs: [String: JSONValue]
                    if case .object(let args) = req.params?["arguments"] {
                        toolArgs = args
                    } else {
                        toolArgs = [:]
                    }

                    do {
                        let toolResult = try handleToolCall(name: toolName, arguments: toolArgs)
                        sendResponse(MCPResponse(id: reqId, result: toolResult))
                    } catch {
                        sendResponse(MCPResponse(id: reqId, error: .internalError(error.localizedDescription)))
                    }

                default:
                    // If notification (no id), ignore. Otherwise return methodNotFound.
                    if req.id != nil && req.id != .null {
                        sendResponse(MCPResponse(id: reqId, error: .methodNotFound(req.method)))
                    }
                }
            }
        }
    }
}

let server = MCPServer()
server.run()
