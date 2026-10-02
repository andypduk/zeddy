import Foundation
import ZeddyCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("zeddy: \(message)\n".utf8))
    exit(1)
}

func decode<T: Decodable>(_ response: IPC.Response, as type: T.Type) -> T? {
    guard let value = response.data, let data = try? IPC.encoder.encode(value) else { return nil }
    return try? IPC.decoder.decode(T.self, from: data)
}

func request(_ method: String, _ params: [String: JSONValue] = [:]) -> IPC.Response {
    do {
        let response = try DaemonClient().call(method, params)
        if !response.ok { fail(response.error ?? "request failed") }
        return response
    } catch { fail("\(error). Start it with: zeddy daemon start") }
}

func option(_ name: String, from args: inout [String]) -> String? {
    let flag = "--\(name)"
    if let index = args.firstIndex(of: flag), index + 1 < args.count {
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return value
    }
    if let index = args.firstIndex(where: { $0.hasPrefix(flag + "=") }) {
        let value = String(args[index].dropFirst(flag.count + 1))
        args.remove(at: index)
        return value
    }
    return nil
}

func flag(_ name: String, from args: inout [String]) -> Bool {
    let value = "--\(name)"
    guard let index = args.firstIndex(of: value) else { return false }
    args.remove(at: index)
    return true
}

func projectPath(_ raw: String?) -> String? {
    raw.map { ($0 as NSString).expandingTildeInPath }
}

func help() {
    print("""
    zeddy — local, token-budgeted memory for Zed workflows

    Usage:
      zeddy add --title TITLE --content TEXT [--kind global|project] [--project PATH] [--tags a,b]
      zeddy update ID [--title TITLE] [--content TEXT] [--kind global|project] [--project PATH] [--tags a,b]
      zeddy list [--kind global|project] [--project PATH]
      zeddy get ID | delete ID
      zeddy search QUERY [--limit N] [--project PATH]
      zeddy context PROMPT [--project PATH] [--stdout]
      zeddy stats | settings [--set-total N] [--set-project-ratio RATIO] [--set-min-score SCORE]
      zeddy export [--out FILE] | import --in FILE
      zeddy prune [--days N]
      zeddy daemon start|stop|status
      zeddy app

    State is stored only in ~/.zeddy (or ZEDDY_HOME).
    """)
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()

switch command {
case "add", "remember":
    let title = option("title", from: &args) ?? "Memory"
    let project = projectPath(option("project", from: &args))
    let kind = Memory.Kind(rawValue: option("kind", from: &args) ?? (project == nil ? "global" : "project")) ?? .global
    let tags = (option("tags", from: &args) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let content = option("content", from: &args) ?? args.joined(separator: " ")
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("--content is required") }
    let response = request("add", JSONValue.encode(AddPayload(kind: kind, title: title, content: content, projectPath: project, tags: tags)).objectValue ?? [:])
    if let memory: Memory = decode(response, as: Memory.self) { print("added \(memory.id.uuidString)") }
case "update", "edit":
    guard let id = args.first else { fail("memory ID is required") }
    args.removeFirst()
    let title = option("title", from: &args)
    let project = projectPath(option("project", from: &args))
    let kind = option("kind", from: &args).flatMap(Memory.Kind.init(rawValue:))
    let tags = option("tags", from: &args).map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    let content = option("content", from: &args) ?? (args.isEmpty ? nil : args.joined(separator: " "))
    let response = request("update", JSONValue.encode(UpdatePayload(id: id, kind: kind, title: title, content: content, projectPath: project, tags: tags)).objectValue ?? [:])
    if let memory: Memory = decode(response, as: Memory.self) { print("updated \(memory.id.uuidString)") }
case "list", "ls":
    let kind = option("kind", from: &args).flatMap(Memory.Kind.init(rawValue:))
    let project = projectPath(option("project", from: &args))
    let response = request("list", ["kind": kind.map { .string($0.rawValue) } ?? .null, "projectPath": project.map(JSONValue.string) ?? .null])
    let memories: [Memory] = decode(response, as: [Memory].self) ?? []
    for memory in memories { print("\(memory.id.uuidString)\t\(memory.kind.rawValue)\t\(memory.title)") }
case "get", "show":
    guard let id = args.first else { fail("memory ID is required") }
    let response = request("get", ["id": .string(id)])
    guard let memory: Memory = decode(response, as: Memory.self) else { fail("memory not found") }
    print("\(memory.title) [\(memory.kind.rawValue)]\n\(memory.content)")
case "delete":
    guard let id = args.first else { fail("memory ID is required") }
    _ = request("delete", ["id": .string(id)])
    print("deleted \(id)")
case "search":
    let limit = Int(option("limit", from: &args) ?? "8") ?? 8
    let project = projectPath(option("project", from: &args))
    let query = option("query", from: &args) ?? args.joined(separator: " ")
    guard !query.isEmpty else { fail("query is required") }
    let response = request("search", ["q": .string(query), "limit": .int(limit), "projectPath": project.map(JSONValue.string) ?? .null])
    let hits: [SearchHit] = decode(response, as: [SearchHit].self) ?? []
    for hit in hits { print(String(format: "%.4f\t%@\t%@", hit.score, hit.memory.id.uuidString, hit.memory.title)) }
case "context":
    let stdout = flag("stdout", from: &args)
    let project = projectPath(option("project", from: &args))
    let prompt = option("prompt", from: &args) ?? args.joined(separator: " ")
    guard !prompt.isEmpty else { fail("prompt is required") }
    let response = request("build_context", ["prompt": .string(prompt), "projectPath": project.map(JSONValue.string) ?? .null])
    let context: ContextBlock = decode(response, as: ContextBlock.self) ?? ContextBlock(text: "", usedIds: [], usedTokens: 0, budgetTokens: 0)
    if !stdout { print("\(context.usedTokens)/\(context.budgetTokens) estimated tokens; \(context.usedIds.count) memories") }
    print(context.text)
case "stats", "status":
    let response = request("stats")
    if let stats: MemoryStore.Stats = decode(response, as: MemoryStore.Stats.self) { print("memories: \(stats.total)\nby kind: \(stats.byKind)") }
case "settings":
    let setTotal = option("set-total", from: &args).flatMap(Int.init)
    let setRatio = option("set-project-ratio", from: &args).flatMap(Double.init)
    let setMinScore = option("set-min-score", from: &args).flatMap(Double.init)
    if setTotal != nil || setRatio != nil || setMinScore != nil {
        let currentResp = request("settings")
        var current: ZeddySettings = decode(currentResp, as: ZeddySettings.self) ?? ZeddySettings.default
        if let t = setTotal { current.budget.totalTokens = max(0, t) }
        if let r = setRatio { current.budget.projectRatio = min(1.0, max(0.0, r)) }
        if let s = setMinScore { current.minScore = s }
        let updateResp = request("update_settings", JSONValue.encode(current).objectValue ?? [:])
        if let updated: ZeddySettings = decode(updateResp, as: ZeddySettings.self) {
            print("updated settings -> budget: \(updated.budget.totalTokens); project ratio: \(updated.budget.projectRatio); min score: \(updated.minScore)")
        }
    } else {
        let response = request("settings")
        if let settings: ZeddySettings = decode(response, as: ZeddySettings.self) { print("budget: \(settings.budget.totalTokens); project ratio: \(settings.budget.projectRatio); min score: \(settings.minScore)") }
    }
case "prune":
    let days = Int(option("days", from: &args) ?? "90") ?? 90
    let response = request("prune", ["olderThanDays": .int(days)])
    print("pruned \(decode(response, as: Int.self) ?? 0) memories")
case "export":
    let response = request("export")
    guard let base64: String = decode(response, as: String.self), let data = Data(base64Encoded: base64) else { fail("invalid export") }
    if let output = option("out", from: &args) {
        do {
            try data.write(to: URL(fileURLWithPath: projectPath(output)!))
            print("exported \(output)")
        } catch {
            fail("failed to write \(output): \(error)")
        }
    } else { print(String(decoding: data, as: UTF8.self)) }
case "import":
    guard let input = option("in", from: &args) else { fail("--in FILE is required") }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: projectPath(input)!)) else { fail("file not found: \(input)") }
    let response = request("import", ["data": .string(data.base64EncodedString())])
    print("imported \(decode(response, as: Int.self) ?? 0) memories")
case "daemon":
    switch args.first ?? "status" {
    case "start": do { print(try DaemonControl.start() ? "daemon started" : "daemon already running") } catch { fail("\(error)") }
    case "stop": do { try DaemonControl.stop(); print("daemon stopped") } catch { fail("\(error)") }
    default: print(DaemonControl.isRunning() ? "daemon running" : "daemon stopped")
    }
case "app":
    let sibling = ((CommandLine.arguments.first ?? "") as NSString).deletingLastPathComponent + "/zeddy-app"
    guard FileManager.default.isExecutableFile(atPath: sibling) else { fail("zeddy-app binary not found") }
    _ = try? Process.run(URL(fileURLWithPath: sibling), arguments: [])
case "help", "--help", "-h": help()
default: fail("unknown command '\(command)'; run `zeddy help`")
}
