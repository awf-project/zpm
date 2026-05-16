---
title: "Memory Segments"
---


Manage isolated knowledge domains with named memory segments. Each memory is backed by a dedicated Prolog module with independent WAL and snapshot persistence.

## Create a Memory

Create a new memory segment to isolate knowledge for a specific domain:

```bash
# Via CLI (project-scope, stored in .zpm/kb/)
zpm memory create --name feature_auth

# Via CLI (global-scope, stored in $XDG_DATA_HOME/zpm/kb/)
zpm memory create --name shared_profiles --scope global

# Via MCP
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_memory","arguments":{"name":"feature_auth","scope":"project"}}}
```

By default, memories are created in project scope and stored in `.zpm/kb/<name>/` with an empty `knowledge.pl` module header. Use `--scope global` to create a memory in global scope, which stores the memory in `$XDG_DATA_HOME/zpm/kb/<name>/` (defaults to `~/.local/share/zpm/kb/<name>` when `$XDG_DATA_HOME` is unset).

The memory is added to `.zpm/mounts.json` and automatically mounted on the next command.

Memory names must be valid Prolog atoms: start with a lowercase letter, followed by letters, digits, or underscores. Names like `my-memory`, `123abc`, or empty strings are rejected.

## Use a Memory

After creation, you can immediately target the memory with `--memory`:

```bash
# Assert facts into the memory
zpm remember-fact --fact "task_done(login)" --memory feature_auth

# Query the memory
zpm query-logic --goal "task_done(X)" --memory feature_auth
```

Via MCP, pass the `memory` parameter to target a specific segment:

```json
{
  "name": "remember_fact",
  "arguments": {
    "fact": "task_done(login)",
    "memory": "feature_auth"
  }
}
```

Facts asserted into `feature_auth` are isolated — they do not appear in the `default` memory or any other mounted memory.

## Mount Persistence (Manifest)

Memory mount decisions are persisted in `.zpm/mounts.json`, a manifest file that survives across CLI process invocations. At startup, zpm reads this manifest and mounts exactly the listed memories with their specified modes:

- **First boot (migration):** If no manifest exists, zpm scans `.zpm/kb/` and generates the manifest with all discovered memories in read-write mode. This ensures zero disruption on upgrade.
- **Subsequent boots:** zpm reads the manifest instead of scanning the filesystem, ensuring consistent mount state across invocations.
- Mount and unmount decisions persist to the manifest, so they survive process restarts.
- Global-scope memories are stored with absolute paths in the manifest; project-scope memories use relative paths.

In MCP server mode (`zpm serve`), the server is long-lived and mount/unmount operations immediately write to the manifest for CLI coherence.

## Auto-mount (CLI)

Each CLI command runs as a separate process. At startup, zpm reads `.zpm/mounts.json` and automatically mounts every memory listed in the manifest. This means:

- No explicit `memory mount` is needed after `memory create` — the manifest is updated automatically.
- All memories in the manifest are available in every command invocation (without filesystem scanning).
- `memory mount` is used to mount a memory as **read-only** (`--mode ro`) or to re-enable an unmounted memory.
- `memory unmount` persists the unmount decision to the manifest — the memory will not be re-mounted on the next invocation unless explicitly remounted.

## Mount in Read-Only Mode

Mount a memory as read-only to prevent accidental mutations. The read-only mode persists to the manifest:

```bash
zpm memory mount --name project_kb --mode ro
```

Read-only memories:
- Allow all query operations (`query_logic`, `explain_why`, `get_knowledge_schema`, etc.)
- Reject all mutation operations (`remember_fact`, `define_rule`, `forget_fact`, etc.) with a descriptive error
- Are useful when agents need to consult shared knowledge without risk of corruption
- The `ro` mode persists across CLI invocations — no need to re-specify on subsequent commands
- To switch back to read-write, use `zpm memory mount --name project_kb --mode rw`

## Unmount a Memory

Unmount a memory to flush its WAL, free resources, and remove it from the persistent manifest:

```bash
zpm memory unmount --name feature_auth
```

On unmount:
- The write-ahead journal is flushed to disk
- The Prolog module is unloaded from memory
- The entry is removed from `.zpm/mounts.json`
- Subsequent CLI invocations will not automatically mount the memory (unless it is explicitly remounted)
- The memory remains on disk and can be remounted later with `memory mount`

The `default` memory cannot be unmounted — it is required for backward compatibility.

## List Memories

View all currently mounted memories:

```bash
zpm memory list
```

Via MCP:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_memories","arguments":{}}}
```

The response includes each memory's name, scope (project/global), mount status, and access mode (rw/ro).

## Use Global Memories

Create memories in global scope to share across projects:

```bash
zpm memory create --name reviewer_profile --scope global
```

Global memories are stored in `$XDG_DATA_HOME/zpm/kb/` (falls back to `~/.local/share/zpm/kb/` when `$XDG_DATA_HOME` is unset). They are discoverable from any project.

When a memory name exists in both project and global scope, you must qualify it:

```bash
zpm memory mount --name project:reviewer_profile    # mount the project-local one
zpm memory mount --name global:reviewer_profile     # mount the global one
```

Unqualified names are resolved project-first, then global. If found in both, an error prompts you to disambiguate.

## Cross-Memory Queries

Query facts across mounted memories using Prolog module qualification syntax:

```bash
zpm query-logic --goal "feature_auth:task_done(X)"
```

This resolves against the `feature_auth` module regardless of which memory is the current default target. Both memories must be mounted.

## Default Memory

On startup, zpm automatically creates and mounts a `default` memory in `.zpm/kb/default/`. When no `--memory` flag or `memory` parameter is provided, all operations target this memory — preserving full backward compatibility with pre-F021 behavior.

## Persistence

Each memory has independent persistence:
- **WAL**: Write-ahead journal at `.zpm/kb/<name>/journal.wal`
- **Snapshots**: Point-in-time snapshots in the same directory

Use `save_snapshot` and `restore_snapshot` with the `--memory` flag to manage per-memory snapshots:

```bash
zpm save-snapshot --name "checkpoint" --memory feature_auth
zpm restore-snapshot --name "checkpoint" --memory feature_auth
```
