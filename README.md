# Zeddy (ズッディ)

<p align="center">
  <img src="Assets/zeddy-logo-manga.svg" alt="Zeddy Manga Logo" width="420"/>
</p>

<p align="center">
  <strong>Ultra-fast native macOS memory manager, BM25 context engine, and MCP server for Zed & 9Router.</strong>
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> •
  <a href="#features">Features</a> •
  <a href="#gui--menu-bar-dashboard">GUI & Menu Bar</a> •
  <a href="#zed-native-connector">Zed Connector</a> •
  <a href="#9router-integration">9Router Setup</a> •
  <a href="#mcp-server">MCP Server</a> •
  <a href="#cli-reference">CLI Reference</a> •
  <a href="#benchmarks">Benchmarks</a>
</p>

---

## What is Zeddy?

Zeddy solves context bloat and token waste when working with AI coding agents in [Zed](https://zed.dev). Instead of injecting giant documentation dumps or system prompts on every query, Zeddy stores concise project and global engineering memories in a native SQLite FTS5 database.

When you ask a question or run a task, Zeddy computes BM25 relevance scores, selects only matching snippets, and strictly bounds them within a heuristic token budget (default 1,200 tokens).

### Key Features

- **Blazing Fast**: Sub-millisecond queries (averaging 5–7 ms under load) written in pure Swift and Rust. Zero network calls.
- **Token Saver Engine**: Compresses full-project context (~8,000+ tokens) down to ~60–120 tokens (~98% reduction), saving cost and avoiding LLM context dilution.
- **Native macOS GUI & Menu Bar Extra**:
  - Live throughput tracking (`REQ/S`, `TOK/S`, `SAVED`, `LATENCY`) styled identically to 9Router.
  - Quick-glance `INDEXED MEMORIES` viewer directly in the menu bar.
  - Full SwiftUI window (`Zeddy.app`) for searching, tagging, adding, editing, and previewing prompt context.
- **Native Zed Rust Extension**:
  - Slash commands inside Zed: `/zeddy` (list all memories or get prompt context) and `/zeddy-search <query>` (BM25 keyword search).
  - Native WebAssembly connector (`wasm32-wasip1`) compiled directly against the `zed_extension_api`.
- **Model Context Protocol (MCP)**:
  - Stdio MCP server (`zeddy-mcp` or `zeddy mcp`) compatible with Zed, Cursor, Windsurf, and Claude Desktop.
  - Exposes 7 tools: `zeddy_context`, `zeddy_add`, `zeddy_update`, `zeddy_get`, `zeddy_delete`, `zeddy_list`, `zeddy_search`.
- **9Router Integration**:
  - Seamlessly injects prompt memory into models served by 9Router proxy (`http://localhost:20128/v1`).
- **Complete Offline Privacy**:
  - SQLite database stored strictly at `~/.zeddy/data/memories.db` (or `$ZEDDY_HOME`).

---

## Architecture

```text
┌────────────────────────────────────────────────────────────────────────┐
│                               Zed Editor                               │
│                                                                        │
│  Slash Commands: /zeddy, /zeddy-search                                 │
│  Context Server (MCP): zeddy-mcp (stdio)                               │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ 1. BM25 Query
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                        Zeddy Native Core (~/.zeddy)                    │
│                                                                        │
│  • zeddy-daemon (IPC Unix Socket: ~/.zeddy/zeddy.sock)                 │
│  • SQLite FTS5 + BM25 Ranking Engine                                   │
│  • Token Budget Allocator (Default: 1,200 tokens)                      │
│  • 9Router-Style Live Throughput & Usage Tracker                       │
└───────────────────┬────────────────────────────────┬───────────────────┘
                    │                                │
                    │ 2. Token-Capped Context        │ 3. Real-Time Telemetry
                    ▼                                ▼
┌──────────────────────────────────────┐  ┌──────────────────────────────┐
│            9Router Proxy             │  │   Zeddy Menu Bar & GUI App   │
│      (http://localhost:20128/v1)     │  │                              │
│                                      │  │  • REQ/S, TOK/S, SAVED, LAT  │
│      Forward to:                     │  │  • Indexed Memories List     │
│      Claude / OpenAI / DeepSeek      │  │  • Daemon Start/Stop/Restart │
└──────────────────────────────────────┘  └──────────────────────────────┘
```

---

## Quick Start

### 1. Requirements
- macOS 13.0 (Ventura) or newer
- Xcode Command Line Tools (`xcode-select --install`)
- Rust with `wasm32-wasip1` target (for the Zed extension):
  ```sh
  rustup target add wasm32-wasip1
  ```

### 2. Build & Install
Clone the repository and build:

```sh
git clone https://github.com/andypduk/zeddy.git
cd zeddy

# Build binaries, package Zeddy.app & Zeddy.dmg, and install to ~/.local/bin + Zed:
make all
```

Or install individual components:
```sh
make build       # Compile release binaries (.build/release)
make install     # Copy binaries to ~/.local/bin
make app         # Bundle dist/Zeddy.app
make dmg         # Package dist/Zeddy.dmg
make extension   # Build and install Rust Wasm extension into Zed
```

### 3. Launch Daemon & GUI
```sh
# Start the background daemon
zeddy daemon start

# Verify daemon status
zeddy daemon status

# Open the GUI app
open dist/Zeddy.app
# Or: zeddy app
```

---

## GUI & Menu Bar Dashboard

Zeddy comes with a native SwiftUI application (`Zeddy.app`) and a dedicated macOS Menu Bar Extra.

### Menu Bar Extra (Lightning Bolt Icon)
- **Status Indicator**: Shows whether `zeddy-daemon` is running or stopped.
- **Daemon Controls**: Start, Stop, and Restart buttons.
- **Real-Time KPIs**:
  - `REQ/S`: Active request throughput.
  - `TOK/S`: Injected token throughput.
  - `SAVED`: Total tokens saved by context clipping.
  - `LATENCY`: Average query execution time.
- **Indexed Memories**: Quick-glance list showing stored titles, scopes (`globe` for global, `folder` for project), and content snippets.
- **Activity Log**: Last 3 operations with latency badges.

### Main Application Window
- **Memories Tab**: Full searchable list, scope filter (`All`, `Global`, `Project`), and Add/Edit memory sheets.
- **Context Preview Tab**: Enter any sample prompt to test live BM25 retrieval and inspect exact token consumption.
- **Usage & Throughput Tab**: 9Router-style telemetry dashboard with period filters (`live`, `today`, `all`).
- **Settings Tab**: Configure `totalTokens` (default: 1,200), `projectRatio` (default: 0.65), and `minScore`.

---

## Zed Native Connector

Zeddy includes a native Rust WebAssembly extension located at `crates/zed-zeddy`.

### 1. Install Extension
```sh
make extension
```
This builds `target/wasm32-wasip1/release/zed_zeddy.wasm` and installs it into:
`~/Library/Application Support/Zed/extensions/installed/zeddy/`

### 2. Slash Commands in Zed Assistant
Open the Zed Assistant panel (`Cmd-?` or `Cmd-Alt-B`) and use:
- `/zeddy`: Dumps formatted Markdown table of all indexed memories into buffer/chat.
- `/zeddy <prompt>`: Queries BM25 relevance and inserts token-budgeted memory context.
- `/zeddy-search <keyword>`: Executes FTS5 BM25 search across memories and outputs results.

---

## 9Router Integration

Zeddy is designed to pair directly with [9Router](https://github.com/andypduk/9router) running on `http://localhost:20128`.

### Zed Settings (`~/.config/zed/settings.json`)
Configure 9Router as your LLM provider and enable Zeddy context server:

```json
{
  "context_servers": {
    "zeddy": {
      "settings": {}
    }
  },
  "assistant": {
    "default_model": {
      "provider": "9Router",
      "model": "my-combo"
    }
  },
  "language_models": {
    "openai_compatible": {
      "9Router": {
        "api_url": "http://localhost:20128/v1",
        "available_models": [
          {
            "name": "my-combo",
            "display_name": "9Router Combo",
            "max_tokens": 128000,
            "max_output_tokens": 8192
          }
        ]
      }
    }
  }
}
```

### Automatic Memory Injection
When using Zeddy with 9Router, inject memory context into prompts using CLI or MCP:
```sh
# Fetch only relevant memories within token budget:
PROMPT_CONTEXT=$(zeddy context "Refactor auth middleware" --project "$PWD" --stdout)
```

---

## MCP Server

Zeddy provides a Model Context Protocol stdio server (`zeddy-mcp` or `zeddy mcp`).

### Adding to Claude Desktop / Cursor / Windsurf
Add to your client config (e.g. `~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "zeddy": {
      "command": "/absolute/path/to/zeddy",
      "args": ["mcp"]
    }
  }
}
```

Replace `/absolute/path/to/zeddy` with the installed binary path reported by `command -v zeddy`. Use an absolute path in the client configuration.

### Available Tools
| Tool | Description | Arguments |
| :--- | :--- | :--- |
| `zeddy_context` | Build BM25-ranked, token-budgeted context block | `prompt` (string, req), `projectPath` (string) |
| `zeddy_search` | Search memories by query using BM25 | `query` (string, req), `projectPath` (string), `limit` (int) |
| `zeddy_list` | List all memories by scope | `kind` (`global` \| `project`), `projectPath` (string) |
| `zeddy_add` | Store new memory | `title` (req), `content` (req), `kind`, `projectPath`, `tags` |
| `zeddy_update` | Update existing memory | `id` (req), `title`, `content`, `kind`, `projectPath`, `tags` |
| `zeddy_get` | Retrieve memory by UUID | `id` (string, req) |
| `zeddy_delete` | Remove memory by UUID | `id` (string, req) |
| `zeddy_stats` | Inspect memory counts and token budget settings | *(none)* |

---

## CLI Reference

```sh
# --- Daemon Management ---
zeddy daemon start                          # Start Unix socket daemon
zeddy daemon stop                           # Stop daemon
zeddy daemon status                         # Check if running

# --- Memory CRUD ---
# Add global memory
zeddy add --title "Swift Performance" --content "Prefer structs and inline arrays."

# Add project memory
zeddy add --title "Zeddy Architecture" --kind project --project "$PWD" \
  --content "Zeddy uses SQLite FTS5 BM25 with token budgeting." --tags "architecture,fts5"

# List memories
zeddy list [--kind global|project] [--project PATH]

# Search memories
zeddy search "BM25 ranking" [--project PATH] [--limit 10]

# Generate context block for LLM prompt
zeddy context "How does retrieval work?" --project "$PWD" --stdout

# Inspect / Update / Delete
zeddy get <UUID>
zeddy update <UUID> --title "New Title" --content "New Content"
zeddy delete <UUID>

# --- Telemetry & Analytics ---
zeddy usage [--period live|today|all]       # 9Router-style usage report
zeddy throughput                            # Live req/s and tok/s metrics

# --- Configuration & Maintenance ---
zeddy settings                              # View active settings
zeddy settings --set-total 1500 --set-project-ratio 0.70 --set-min-score 0.0
zeddy export [--out backup.json]            # Backup all memories
zeddy import --in backup.json               # Restore memories
zeddy prune --days 90                       # Prune unused memories

# --- Launchers ---
zeddy app                                   # Open SwiftUI GUI
zeddy mcp                                   # Run stdio MCP server
```

---

## Benchmarks & Verification

Run the automated test suite and smoke test:

```sh
# Unit Tests (6/6 passing)
swift test

# Full End-to-End Smoke Test (10/10 stages passing)
./smoke_test.sh
```

### Benchmark Results
- **Query Latency**: ~5–7 ms per context query under 50-query concurrent bursts.
- **In-Process Fallback**: If `zeddy-daemon` is stopped, the CLI automatically falls back to direct SQLite storage in 0.5 ms.
- **Token Reduction**: Compresses an 8,000+ token codebase prompt to ~70 tokens (~98% reduction).

---

## File Locations & Storage

All local state resides in `~/.zeddy/` (or `$ZEDDY_HOME`):

```text
~/.zeddy/
├── data/
│   └── memories.db       # SQLite3 database with FTS5 virtual tables
├── settings.json         # Token budget and threshold settings
├── zeddy.sock            # Unix domain socket for IPC
├── zeddy-daemon.pid      # Daemon PID file
└── zeddy.log             # Daemon execution and error logs
```

---

## License

MIT License. See [LICENSE](LICENSE) for details.
