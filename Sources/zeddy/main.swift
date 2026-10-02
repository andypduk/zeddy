import Foundation
import ZeddyCore

// zeddy — a fast, token-frugal memory engine for Zed.
//
// The CLI is the integration surface. Zed (or you) invoke it in a terminal:
//   zeddy remember ...   store a memory
//   zeddy context ...    emit a compact context block (pipe to a prompt)
//   zeddy ls / show ...  inspect
//   zeddy daemon ...     manage the background daemon
//   zeddy app            launch the GUI
//
// All state lives under ~/.zeddy (the daemon owns the store + socket).

// MARK: - Argument parsing

struct Args {
    var command = "help"
    var words: [String] = []      // positional arguments after the command
    var flags: [String: String] = [:] // --key value  /  --key=value
    var bools: Set<String> = []   // --flag

    mutating func consume(_ name: String) -> String? {
        if let i = words.firstIndex(of: "--" + name) {
            guard i + 1 < words.count else { return nil }
            let v = words[i + 1]
            words.removeSubrange(i...(i + 1))
            return v
        }
        if let i = words.firstIndex(where: { $0.hasPrefix("--" + name + "=") }) {
            let v = String(words[i].dropFirst("--" + name + "=".count))
            words.remove(at: i)
            return v
        }
        return nil
    }

    mutating func boolFlag(_ name: String) -> Bool {
        if let i = words.firstIndex(of: "--" + name) {
            words.remove(at: i)
            return true
        }
        if let i = words.firstIndex(where: { $0.hasPrefix("--" + name + "=") }) {
            let v = String(words[i].dropFirst("--" + name + "=".count))
            words.remove(at: i)
            if v == "true" || v == "1" { return true }
            if v == "false" || v == "0" { return false }
        }
        return false
    }
}

func parseArgs(_ argv: [String]) -> Args {
    var a = Args()
    var rest = argv
    while let w = rest.first, !w.hasPrefix("--") {
        a.words.append(w)
        rest.removeFirst()
    }
    // first positional is the command
    if let first = a.words.first, !first.isEmpty {
        a.command = first
        a.words.removeFirst()
    }
    // merge remaining flags into the positional pool (consume/boolFlag scan it)
    a.words.append(contentsOf: rest)
    return a
}

func join(_ s: [String]) -> String { s.joined(separator: " ") }

// MARK: - Helpers

func requireProject(_ args: [String]) -> String? {
    if let p = args.consume("project"), !p.isEmpty {
        return (p as NSString).expandingTildeInPath
    }
    // Default to the current working directory so `zeddy remember ...` from a
    // project folder is project-scoped.
    let cwd = FileManager.default.currentDirectoryPath
    return cwd
}

func printError(_ s: String) {
    FileHandle.standardError.write(Data(("[zeddy] " + s + "\n").utf8))
}

/// Decode a daemon response's `data` JSONValue into a Swift type, or nil.
func decodeData<T: Decodable>(_ resp: IPC.Response, type: T.Type) -> T? {
    guard let d = resp.data else { return nil }
    guard let data = try? IPC.encoder.encode(d) else { return nil }
    return try? IPC.decoder.decode(T.self, from: data)
}

func printResponse(_ resp: IPC.Response) {
    if !resp.ok {
        printError(resp.error ?? "request failed")
        return
    }
    guard let d = resp.data, d != .null else {
        print("ok")
        return
    }
    let out = (try? IPC.encoder.encode(d)) ?? Data()
    print(String(data: out, encoding: .utf8) ?? "")
}

// MARK: - Commands

func cmdRemember(_ args: [String]) {
    let title = args.consume("title") ?? "note"
    let content = args.consume("content") ?? join(args.words)
    if content.isEmpty {
        printError("nothing to remember (provide --content or text arguments)")
        exit(1)
    }
    let kind = (args.consume("kind") ?? "note").lowercased()
    let project = requireProject(args)

    var m = Memory(kind: Memory.Kind(rawValue: kind) ?? .note,
                   title: title, content: content,
                   projectPath: project?.isEmpty == false ? project : nil)
    if let tagsRaw = args.consume("tags") {
        m.tags = tagsRaw.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    let f = DaemonClient.request(.init(.remember(m)))
    guard f.ok else { printError(f.error ?? "remember failed"); exit(1) }
    print("remembered: \(title)")
}

func cmdContext(_ args: [String]) {
    let prompt = args.consume("prompt") ?? join(args.words)
    if prompt.isEmpty { printError("empty prompt"); exit(1) }
    let project = args.consume("project")
        .map { ($0 as NSString).expandingTildeInPath }
    let maxMem = Int(args.consume("max-memories") ?? "") ?? nil
    let maxTok = Int(args.consume("max-tokens") ?? "") ?? nil
    let topTok = Int(args.consume("top-memory-tokens") ?? "") ?? nil
    let stdout = args.boolFlag("stdout")

    var bc = BuildContextPayload(prompt: prompt, projectPath: project?.isEmpty == false ? project : nil)
    if let maxMem { bc.maxMemories = maxMem }
    if let maxTok { bc.maxTokens = maxTok }
    if let topTok { bc.topMemoryTokens = topTok }

    let f = DaemonClient.request(.init(.buildContext(bc)))
    guard f.ok else { printError(f.error ?? "build_context failed"); exit(1) }
    guard let result = decodeData(f, type: BuildContextResult.self) else {
        printError("no context result"); exit(1)
    }

    if stdout {
        // Machine-readable for piping straight into a prompt.
        print(result.context)
    } else {
        print("Context for: \(prompt)")
        print("  memories: \(result.selectedCount)")
        print("  tokens:   \(result.estimatedTokens)")
        print("")
        print(result.context)
    }
}

func cmdSearch(_ args: [String]) {
    let query = args.consume("query") ?? join(args.words)
    if query.isEmpty { printError("empty query"); exit(1) }
    let limit = Int(args.consume("limit") ?? "") ?? 8
    let project = args.consume("project").map { ($0 as NSString).expandingTildeInPath }

    let f = DaemonClient.request(.init(.search(SearchPayload(query: query, projectPath: project?.isEmpty == false ? project : nil, limit: limit))))
    guard f.ok else { printError(f.error ?? "search failed"); exit(1) }
    guard let hits = decodeData(f, type: [SearchHit].self) else { print("no results"); return }
    guard !hits.isEmpty else { print("no results"); return }
    for h in hits {
        let proj = h.memory.projectPath.map { " [\($0)]" } ?? ""
        print(String(format: "  (%6.2f) %@", h.score, h.memory.title) + proj)
        print("    id: \(h.memory.id)")
    }
}

struct ListRow: Decodable {
    let id: String
    let kind: String
    let title: String
    let projectPath: String?
    let tags: [String]
    let createdAt: Double
    let lastUsedAt: Double?
    let useCount: Int
}

func cmdList(_ args: [String]) {
    var p = ListPayload()
    if let k = args.consume("kind"), !k.isEmpty { p.kind = Memory.Kind(rawValue: k) }
    if let proj = args.consume("project") { p.projectPath = (proj as NSString).expandingTildeInPath }
    if let tag = args.consume("tag"), !tag.isEmpty { p.tag = tag }

    let f = DaemonClient.request(.init(.list(p)))
    guard f.ok else { printError(f.error ?? "list failed"); exit(1) }
    guard let rows = decodeData(f, type: [ListRow].self) else { print("(empty)"); return }
    guard !rows.isEmpty else { print("(no memories)"); return }
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm"
    for r in rows {
        let proj = r.projectPath.map { " \($0)" } ?? ""
        let tags = r.tags.isEmpty ? "" : " #" + r.tags.joined(separator: "#")
        print("\(r.kind)\t\(r.title)\t\(df.string(from: Date(timeIntervalSince1970: r.createdAt)))\(proj)\(tags)")
        print("  \(r.id)")
    }
}

func cmdShow(_ args: [String]) {
    guard let rawId = args.consume("id") ?? args.words.first,
          let id = UUID(uuidString: rawId) else {
        printError("provide a valid memory id"); exit(1)
    }
    let f = DaemonClient.request(.init(.get(id)))
    guard f.ok else { printError(f.error ?? "get failed"); exit(1) }
    guard let m = decodeData(f, type: Memory.self) else { printError("not found"); exit(1) }
    print("id:      \(m.id)")
    print("kind:    \(m.kind)")
    print("title:   \(m.title)")
    if let p = m.projectPath { print("project: \(p)") }
    if !m.tags.isEmpty { print("tags:    " + m.tags.joined(separator: ", ")) }
    print("content:")
    print(m.content)
}

func cmdDelete(_ args: [String]) {
    guard let id = args.consume("id") ?? args.words.first, UUID(uuidString: id) != nil else {
        printError("provide a valid memory id"); exit(1)
    }
    let f = DaemonClient.request(.init(.delete(id)))
    guard f.ok else { printError(f.error ?? "delete failed"); exit(1) }
    print("deleted \(id)")
}

func cmdPrune(_ args: [String]) {
    let days = Int(args.consume("days") ?? "") ?? 30
    let f = DaemonClient.request(.init(.prune(PrunePayload(days: days))))
    guard f.ok else { printError(f.error ?? "prune failed"); exit(1) }
    if let n = decodeData(f, type: Int.self) { print("pruned \(n) memory(ies)") } else { print("ok") }
}

struct SettingsEcho: Decodable { let data: JSONValue }

func cmdSettings(_ args: [String]) {
    let f = DaemonClient.request(.init(.getSettings))
    guard f.ok else { printError(f.error ?? "settings failed"); exit(1) }
    guard let s = decodeData(f, type: ZeddySettings.self) else { printError("no settings"); exit(1) }
    print("maxTokens:        \(s.maxTokens)")
    print("maxMemories:      \(s.maxMemories)")
    print("topMemoryTokens:  \(s.topMemoryTokens)")
    print("minScore:         \(s.minScore)")
    print("pruneAfterDays:   \(s.pruneAfterDays)")
    print("includeProject:   \(s.includeProject)")
    print("includeGlobal:    \(s.includeGlobal)")
}

func cmdStatus(_ args: [String]) {
    let stat = DaemonClient.status()
    print("daemon:   \(stat.socketPath)\(stat.socketPresent ? "" : "  (not running)")")
    print("store:    \(Paths.dbFile)")
    print("log:      \(Paths.daemonLogPath)")

    let sf = DaemonClient.statusFrame()
    guard sf.ok, let s = decodeData(sf, type: DaemonStatus.self) else {
        printError("could not reach daemon (is it running? try: zeddy daemon start)")
        exit(1)
    }
    print("db:       \(s.store.databasePath)  (memories: \(s.store.total))")
    print("sqlite:   \(s.store.libraryVersion)   uptime: \(s.uptimeSeconds)s")
}

func cmdExport(_ args: [String]) {
    let f = DaemonClient.request(.init(.export))
    guard f.ok else { printError(f.error ?? "export failed"); exit(1) }
    guard let b64 = decodeData(f, type: String.self) else { printError("no export data"); exit(1) }
    guard let data = Data(base64Encoded: b64) else { printError("bad export data"); exit(1) }
    // Write to a file if given, else stdout.
    if let out = args.consume("out"), !out.isEmpty {
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        do {
            try data.write(to: url)
            print("exported to \(url.path)")
        } catch {
            printError("could not write export: \(error.localizedDescription)")
            exit(1)
        }
    } else {
        print(String(data: data, encoding: .utf8) ?? "")
    }
}

func cmdImport(_ args: [String]) {
    guard let inPath = args.consume("in") ?? args.words.first, !inPath.isEmpty else {
        printError("provide a path to a .json export"); exit(1)
    }
    let url = URL(fileURLWithPath: (inPath as NSString).expandingTildeInPath)
    guard let data = try? Data(contentsOf: url) else { printError("could not read \(url.path)"); exit(1) }
    let b64 = data.base64EncodedString()
    let f = DaemonClient.request(.init(.import(base64: b64)))
    guard f.ok else { printError(f.error ?? "import failed"); exit(1) }
    if let n = decodeData(f, type: Int.self) { print("imported \(n) memory(ies)") } else { print("ok") }
}

func cmdDaemon(_ args: [String]) {
    let sub = args.words.first ?? "status"
    switch sub {
    case "start":
        do {
            if try DaemonControl.start() {
                print("daemon started (socket: \(Paths.daemonSocketPath))")
            } else {
                print("daemon already running")
            }
        } catch {
            printError(error.localizedDescription); exit(1)
        }
    case "stop":
        do { try DaemonControl.stop(); print("sent stop signal to daemon") }
        catch { printError(error.localizedDescription); exit(1) }
    case "status":
        cmdStatus(args)
    case "restart":
        do { try DaemonControl.stop(); try? Foundation.Task.sleep(nanoseconds: 300_000_000); _ = try DaemonControl.start(); print("daemon restarted") }
        catch { printError(error.localizedDescription); exit(1) }
    default:
        printError("unknown daemon subcommand: \(sub) (try: start, stop, restart, status)")
        exit(1)
    }
}

func cmdApp(_ args: [String]) {
    // Reuse the same resolution as DaemonControl, but for the app binary.
    let env = ProcessInfo.processInfo.environment["ZEDDY_APP"]
    var candidates: [String] = []
    if let env, !env.isEmpty { candidates.append(env) }
    if let self = ProcessInfo.processInfo.arguments.first {
        candidates.append((self as NSString).deletingLastPathComponent().appending("/zeddy-app"))
    }
    candidates.append((NSHomeDirectory() as NSString).appendingPathComponent(".zeddy/bin/zeddy-app"))

    guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        printError("zeddy-app binary not found (set ZEDDY_APP to its path)")
        exit(1)
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.currentDirectoryURL = FileManager.default.url(atPath: FileManager.default.currentDirectoryPath)
    do {
        try p.run()
        print("launched zeddy-app")
    } catch {
        printError("could not launch app: \(error.localizedDescription)"); exit(1)
    }
}

func cmdHelp() {
    let help = """
    zeddy — a fast, token-frugal memory engine for Zed

    USAGE
      zeddy <command> [options]

    MEMORY
      remember [--title t] [--kind n] [--tags a,b] [--project p] [text...]
               Store a memory. --kind: note|convention|decision|preference
               [text...] (with no --content) becomes the content.
      context [--prompt t] [--project p] [--max-memories n] [--max-tokens n]
              [--top-memory-tokens n] [--stdout]
              Emit a compact context block of the most relevant memories.
              --stdout prints only the block (pipe it into a prompt).
      search <query...> [--limit n] [--project p]
      ls [--kind n] [--project p] [--tag t]
      show <id>
      delete <id>
      prune [--days n]
      settings

    DAEMON
      daemon [start|stop|restart|status]

    APP
      app            Launch the zeddy-app GUI.

    ALL data lives under ~/.zeddy (store: ~/.zeddy/zeddy.db).
    The daemon is required for most commands; start it with `zeddy daemon start`.
    """
    print(help)
}

// MARK: - main

let argv = Array(CommandLine.arguments.dropFirst())
let args = parseArgs(argv)
let a = args.words

switch args.command {
case "remember": cmdRemember(a)
case "context": cmdContext(a)
case "search": cmdSearch(a)
case "ls", "list": cmdList(a)
case "show": cmdShow(a)
case "delete": cmdDelete(a)
case "prune": cmdPrune(a)
case "settings": cmdSettings(a)
case "status": cmdStatus(a)
case "export": cmdExport(a)
case "import": cmdImport(a)
case "daemon": cmdDaemon(a)
case "app": cmdApp(a)
case "help", "--help", "-h", "": cmdHelp()
default:
    printError("unknown command: \(args.command)")
    printError("run `zeddy help` for usage")
    exit(1)
}
