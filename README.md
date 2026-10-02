# Zeddy

<p align="center">
  <img src="Assets/zeddy-logo-manga.svg" alt="Zeddy Manga Logo" width="380"/>
</p>

Zeddy is a local native macOS memory service for AI-assisted development in Zed. It stores concise project and global memories, finds only the memories relevant to the current task with SQLite FTS5/BM25, and emits a context block constrained by a hard, heuristic token budget.

It consists of:

- `zeddy-daemon` — a Unix-socket daemon that owns the SQLite FTS5 store.
- `zeddy` — a dependency-free CLI suitable for scripts and Zed agent/tool workflows.
- `zeddy-app` — a SwiftUI app for browsing, editing, previewing context, and configuring the budget.

## Storage and privacy

All mutable Zeddy data stays on the local machine under:

```text
~/.zeddy/
├── data/memories.db
├── settings.json
├── zeddy.sock
├── zeddy-daemon.pid
└── zeddy.log
```

Set `ZEDDY_HOME` to use a different directory (useful for testing or separate profiles). Zeddy makes no network requests and has no package dependencies.

## Build

Requires macOS 13+ and the Xcode command-line tools.

```sh
swift build -c release
swift test
```

The built executables are in `.build/release/`. To use the daemon-management command from a copied installation, either keep all three executables together or set `ZEDDY_DAEMON` to the full path of `zeddy-daemon`.

## CLI

```sh
# Start the local daemon
zeddy daemon start

# Store global or project-specific knowledge
zeddy add --title "Testing" --content "Use focused XCTest cases before broad runs."
zeddy add --title "Architecture" --kind project --project /path/to/repo \
  --content "The UI calls the service layer; keep persistence behind repositories."

# Retrieve or emit only relevant context
zeddy search "how are tests structured" --project /path/to/repo
zeddy context "Add coverage for the service layer" --project /path/to/repo --stdout

# Inspect and update settings
zeddy settings
zeddy settings --set-total 1500 --set-project-ratio 0.70 --set-min-score 0.0

# Manage stored data
zeddy list
zeddy get MEMORY_ID
zeddy update MEMORY_ID --title "Updated Title" --content "Updated content"
zeddy delete MEMORY_ID
zeddy export --out zeddy-backup.json
zeddy import --in zeddy-backup.json
zeddy prune --days 90

# Launch the SwiftUI manager
zeddy app
```

The `context --stdout` command prints only the prompt-ready memory block. The token figure is a conservative heuristic (not an exact tokenizer for every AI model).

## Full setup & configuration

### 1. Installation

Build the release binaries:

```sh
# Compile release binaries
make build

# Package standalone macOS App bundle in dist/Zeddy.app
make app

# Package drag-to-install DMG in dist/Zeddy.dmg
make dmg

# Or install binaries to ~/.local/bin
make install
```

Manual copy:

```sh
cp .build/release/zeddy .build/release/zeddy-daemon .build/release/zeddy-app .build/release/zeddy-mcp /usr/local/bin/
```

*Note: `zeddy-daemon` and `zeddy-app` should stay in the same directory as `zeddy`, or specify daemon binary path via `ZEDDY_DAEMON=/path/to/zeddy-daemon`.*

### 2. Daemon setup

Start the background daemon process:

```sh
zeddy daemon start
```

Check status:

```sh
zeddy daemon status
```

To stop:

```sh
zeddy daemon stop
```

Optional auto-start: create a launchd agent at `~/Library/LaunchAgents/com.zeddy.daemon.plist` pointing to `zeddy-daemon`.

### 3. Settings & configuration

Settings live in `~/.zeddy/settings.json` (or `$ZEDDY_HOME/settings.json`).

#### View settings:
```sh
zeddy settings
```

#### Change settings via CLI:
```sh
zeddy settings --set-total 1600 --set-project-ratio 0.70 --set-min-score 0.0
```

- `--set-total <N>`: Maximum token budget across all retrieved memories (default: 1200).
- `--set-project-ratio <RATIO>`: Proportion (0.0 to 1.0) reserved for project-specific memories (default: 0.65). Remainder is used for global memories.
- `--set-min-score <SCORE>`: Minimum BM25 relevance score required for inclusion (default: 0.0).

#### Change settings via GUI:
Run `zeddy app`, select the **Settings** tab (gear icon), adjust the token budget and ratio sliders, and click **Save Settings**.

#### Direct JSON configuration (`~/.zeddy/settings.json`):
```json
{
  "budget": {
    "totalTokens": 1200,
    "projectRatio": 0.65
  },
  "indexRefreshInterval": 5,
  "minScore": 0.0
}
```

## Zed & 9Router integration

Zeddy acts as local, token-budgeted memory layer for Zed when routing through model proxies like **9Router** (or any OpenAI-compatible provider).

### Architecture

```text
┌────────────────────────────────────────────────────────┐
│                      Zed Editor                        │
│                                                        │
│  Assistant / Agent Workflow                            │
│  "zeddy context --project $PWD --stdout <prompt>"      │
└───────────────┬────────────────────────────────────────┘
                │ 1. Fetches concise context
                ▼
┌───────────────────────────────┐
│     Zeddy Daemon (~/.zeddy)   │
│  SQLite FTS5 + BM25 Ranking   │
│  Enforces token budget limit  │
└───────────────┬───────────────┘
                │ 2. Prompt + token-capped memory block
                ▼
┌───────────────────────────────┐
│        9Router Proxy          │
│   (http://localhost:20128/v1) │
└───────────────┬───────────────┘
                │ 3. Forward to targeted model
                ▼
┌───────────────────────────────┐
│       Language Model          │
│ (Claude / OpenAI / Local LLM) │
└───────────────────────────────┘
```

## Native Zed connector (Rust Extension)

Zeddy includes a native Rust WebAssembly Zed extension (`crates/zed-zeddy`) compiled against the official `zed_extension_api`.

It gives Zed:
- **Automatic Context Server**: Launches `zeddy-mcp` automatically as a Zed context server.
- **Slash Commands**: `/zeddy` and `/zeddy-search` inside the Zed Assistant panel.

### Install extension into Zed

```sh
# Build Rust Wasm extension and install into ~/Library/Application Support/Zed/extensions/installed/zeddy
make extension
```

Or full install:

```sh
make install
```

### 1. Configure Zed with 9Router & Zeddy context server

In `~/.config/zed/settings.json`, set 9Router as the language model provider and enable `zeddy`:

```json
{
  "context_servers": {
    "zeddy": {
      "settings": {}
    }
  }
}
```

```json
{
  "assistant": {
    "default_model": {
      "provider": "9Router",
      "model": "my-combo",
      "enable_thinking": false
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

### 2. Connect Zeddy Memory to Zed Workflows

#### Option A: Zed Assistant Terminal / Shell Tool

When running Zed assistant or agent loops with terminal tool permissions:

```sh
# Fetch only relevant memories for the prompt under token budget:
CONTEXT=$(zeddy context --project "$PWD" --stdout "$PROMPT")
```

#### Option B: Model Context Protocol (MCP) in Claude, Cursor, Windsurf, & Zed

Zeddy includes a native stdio MCP server target (`zeddy-mcp` or `zeddy mcp`).

Add to your MCP configuration (e.g. `claude_desktop_config.json`, Cursor MCP settings, or Zed MCP configuration):

```json
{
  "mcpServers": {
    "zeddy": {
      "command": "zeddy",
      "args": ["mcp"]
    }
  }
}
```

Or reference the compiled binary directly:

```json
{
  "mcpServers": {
    "zeddy": {
      "command": "/usr/local/bin/zeddy-mcp"
    }
  }
}
```

Exposed MCP tools:
- `zeddy_context(prompt, projectPath)`: Build BM25-ranked, token-budgeted memory context.
- `zeddy_add(title, content, kind, projectPath, tags)`: Add new memory snippet.
- `zeddy_search(query, projectPath, limit)`: Full-text search memories.
- `zeddy_list(kind, projectPath)`: List memories by scope.
- `zeddy_get(id)`: Retrieve memory by UUID.
- `zeddy_delete(id)`: Remove memory by UUID.
- `zeddy_stats()`: Inspect count and token budget.

#### Option C: Global Agent Rules (`~/.config/zed/AGENTS.md`)

Add the following memory retrieval pattern to your global agent instructions:

```markdown
## Persistent Memory (Zeddy)

Before tackling non-trivial tasks or answering architecture questions:
1. Query relevant memories:
   `zeddy context --project "$PWD" --stdout "<brief task query>"`
2. If context is returned, treat it as authoritative project or global conventions.
3. To remember new patterns or decisions:
   `zeddy add --kind project --project "$PWD" --title "<Title>" --content "<Rule>"`
```

#### Option D: Zed Task (`.zed/tasks.json`)

Define a task to extract and print context directly inside any project:

```json
[
  {
    "label": "Zeddy: Fetch Context",
    "command": "zeddy context --project \"$ZED_WORKTREE_ROOT\" --stdout \"$ZED_SELECTED_TEXT\"",
    "use_new_terminal": false,
    "allow_concurrent_runs": false
  }
]
```

### Why use Zeddy with 9Router & Zed?

- **Zero API token waste**: Instead of dumping large documentation files into every request to 9Router, Zeddy dynamically pulls only BM25-relevant rules up to the configured token budget (e.g. 1,200 tokens).
- **Reduced latency**: Small prompt sizes route and complete significantly faster through 9Router.
- **Privacy & offline persistence**: Knowledge rules remain locally stored in SQLite FTS5 (`~/.zeddy/data/memories.db`), independent of cloud providers.

## How token reduction works

1. Memories are stored once locally in SQLite.
2. SQLite FTS5 retrieves the highest-relevance project and global memories using BM25.
3. Zeddy assigns the configured budget between project and global scopes.
4. It adds rendered memories only if their conservative estimated cost fits, including headers and metadata.
5. The compact result is returned instead of repeatedly sending every historical memory.

Use the **Context** tab in `zeddy-app` to see the exact context that would be passed to an AI workflow and its estimated token cost.
