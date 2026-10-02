import Foundation
import ZeddyCore

// MARK: - Option parsing

/// A tiny dependency-free command-line option parser.
///
/// Supports `--key value`, `--key=value`, boolean `--flag`, and collects
/// everything else as positionals. Good enough for a dev tool without pulling
/// in ArgumentParser (which needs a network fetch).
struct OptParser {
    let positionals: [String]
    let values: [String: String]
    let flags: Set<String>

    init(_ argv: [String], boolFlags: Set<String> = []) {
        var pos: [String] = []
        var vals: [String: String] = [:]
        var fl: Set<String> = []
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            if arg.hasPrefix("--") {
                let body = String(arg.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    // --key=value
                    let key = String(body[body.startIndex..<eq])
                    let val = String(body[body.index(after: eq)...])
                    vals[key] = val
                } else if boolFlags.contains(body) {
                    fl.insert(body)
                } else if i + 1 < argv.count {
                    vals[body] = argv[i + 1]
                    i += 1 // consume the value
                } else {
                    fl.insert(body) // trailing flag with no value
                }
            } else {
                pos.append(arg)
            }
            i += 1
        }
        positionals = pos
        values = vals
        flags = fl
    }

    func string(_ key: String) -> String? { values[key] }
    func int(_ key: String) -> Int? { values[key].flatMap(Int.init) }
    func double(_ key: String) -> Double? { values[key].flatMap(Double.init) }
    func has(_ flag: String) -> Bool { flags.contains(flag) }

    /// Comma/space separated list (for tags).
    func list(_ key: String) -> [String]? {
        values[key].map {
            $0.split(whereSeparator: { $0 == "," || $0 == " " })
                .map(String.init)
                .filter { !$0.isEmpty }
        }
    }

    /// All remaining positional arguments joined (for free-text query/prompt).
    var joinedPositionals: String { positionals.joined(separator: " ") }
}

// MARK: - JSONValue -> typed decoding

extension JSONValue {
    /// Re-encode this value to bytes and decode it as `T`.
    ///
    /// The daemon hands results back as a `JSONValue` tree; clients (CLI/GUI)
    /// re-encode that tree and decode the typed payload. `Memory` self-encodes
    /// its dates as epoch doubles and `Stats`/`Settings` use Foundation's
    /// default date strategy, so a plain `JSONDecoder` round-trips everything.
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? IPC.encoder.encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func decode<T: Decodable>(_ type: T.Type, from v: JSONValue?) -> T? {
        v?.decode(type)
    }
}

extension IPC.Response {
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        JSONValue.decode(type, from: data)
    }

    /// Human-readable error text for a failed response.
    var failureText: String { error ?? "request failed" }
}

// MARK: - Output formatting

/// Minimal aligned table printer for human-readable CLI output.
enum Out {
    static func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    static func out(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }

    static func table(_ headers: [String], _ rows: [[String]]) {
        var cols = headers
        for r in rows {
            for (i, cell) in r.enumerated() where i < cols.count {
                cols[i] = max(cols[i], cell.count)
            }
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { i, c in
                i == cells.count - 1 ? c : c.padding(toLength: cols[i], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        out(line(headers))
        out(cols.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        for r in rows { out(line(r)) }
    }

    static func bytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        let kb = Double(n) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    static func relTime(_ date: Date?) -> String {
        guard let date else { return "never" }
        let s = Int(date.timeIntervalSinceNow.magnitude)
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    static func tokens(_ m: Memory) -> Int {
        TokenEstimator.estimateRendered(title: m.title, body: m.content)
    }
}

/// Shared renderer for a `Memory` (used by the CLI's `get`).
func renderMemoryDetail(_ m: Memory) -> String {
    let proj = m.projectPath.map { "  project: \($0)\n" } ?? ""
    let tags = m.tags.isEmpty ? "" : "  tags:    \(m.tags.joined(separator: ", "))\n"
    return """
    id:        \(m.id.uuidString)
    kind:      \(m.kind.rawValue)
    title:     \(m.title)
    created:   \(m.createdAt.formatted(date: .abbreviated, time: .shortened))
    used:      \(m.useCount)×  (last: \(Out.relTime(m.lastUsedAt)))
    est. tokens: \(Out.tokens(m))
    \(proj)\(tags)\n    content:\n    \(indented(m.content))
    """
}

func indented(_ s: String, prefix: String = "    ") -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
}
