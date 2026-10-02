# Zeddy

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

## Zed integration

Zeddy does not claim an unverified native Zed context-server protocol. Integrate it through a Zed agent/tool or terminal workflow that knows the current prompt and project path:

```sh
zeddy context --project "$PROJECT_ROOT" --stdout "$TASK_PROMPT"
```

Inject that command's output into the model context only when it is non-empty. This preserves Zed's existing workflow while replacing large, always-included memory files with FTS-ranked, budget-capped context.

## How token reduction works

1. Memories are stored once locally in SQLite.
2. SQLite FTS5 retrieves the highest-relevance project and global memories using BM25.
3. Zeddy assigns the configured budget between project and global scopes.
4. It adds rendered memories only if their conservative estimated cost fits, including headers and metadata.
5. The compact result is returned instead of repeatedly sending every historical memory.

Use the **Context** tab in `zeddy-app` to see the exact context that would be passed to an AI workflow and its estimated token cost.
