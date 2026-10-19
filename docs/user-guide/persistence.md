---
title: "Knowledge Base Persistence"
---


Learn how to save and restore your knowledge base across server restarts using snapshots and automatic journal recovery.

## Overview

zpm persists your knowledge base using two mechanisms:

1. **Write-Ahead Journal (WAL)** — Every fact assertion or retraction is logged before being written to memory, ensuring durability
2. **Point-in-Time Snapshots** — Named snapshots capture the full knowledge base state at a moment in time

The server automatically recovers from the most recent snapshot plus subsequent journal entries on startup, preventing data loss.

## Create a Snapshot

Use `save_snapshot` to create a named checkpoint of your knowledge base:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "save_snapshot",
    "arguments": {
      "name": "backup_2026_04_13"
    }
  }
}
```

Before publication, zpm writes the checkpoint to a temporary file and loads that
closed file in a fresh Prolog engine. The snapshot is renamed into place only
after it passes this validation. After a successful snapshot:

- The journal is rotated and eligible archived journals are cleaned up
- You can restore to this exact state later
- The snapshot uses human-readable Prolog source format

If serialization or fresh-engine validation fails, zpm removes only the
temporary candidate. The previous checkpoint and active journal remain in
place, so the failed save does not destroy the last recoverable state.

## List Available Snapshots

Query all available snapshots to see what restore points exist:

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "list_snapshots",
    "arguments": {}
  }
}
```

Response includes snapshot names, timestamps, and sizes to help you choose which to restore.

## Restore from a Snapshot

Use `restore_snapshot` to return to a previous state:

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "restore_snapshot",
    "arguments": {
      "name": "backup_2026_04_13"
    }
  }
}
```

The restore process:
1. Loads the snapshot, replacing the current knowledge base
2. Asserts all facts from the snapshot as immediately queryable predicates
3. Replays all journal entries recorded after the snapshot
4. Returns to the exact state including any facts added since the snapshot

**Important:** All predicates in the snapshot are loaded as dynamic, so they are fully accessible via `query_logic` and reflected in `get_knowledge_schema` counts immediately after restore. The snapshot mechanism uses human-readable Prolog source format with explicit `:- dynamic(F/A).` directives to ensure reliable round-trip behavior.

This enables point-in-time recovery without losing recent changes.

## Monitor Persistence Status

Check the status of your persistence layer (journal size, last snapshot, operational mode):

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "tools/call",
  "params": {
    "name": "get_persistence_status",
    "arguments": {}
  }
}
```

Status includes:
- `journal_size` — Current write-ahead log size in bytes
- `last_snapshot` — Name and timestamp of the most recent snapshot
- `mode` — "normal" (persistence active) or "degraded" (persistence unavailable, in-memory only)

## Degraded Mode

If the persistence directory is not writable, zpm starts in **degraded mode**:
- The server runs normally with all tools available
- Facts and rules are held in memory only
- No snapshots or journal entries are created
- On restart, the knowledge base starts empty

Once the persistence directory is writable again, the server automatically returns to normal mode.

## Manual Inspection

Snapshots and journal entries use human-readable Prolog source format, so you can inspect them manually:

```prolog
% Example snapshot (Prolog code)
fact(a).
fact(b).
rule(X) :- fact(X), other_fact(X).

% Example journal entry
%% 1712973249000 assert new_fact(value).
%% 1712973250000 retract old_fact(value).
```

This human-readable format enables:
- Easy debugging and auditing
- Manual fact correction if needed (after making a byte-for-byte backup)
- Integration with standard Prolog tools

## Recover an Invalid Snapshot Safely

ZPM v0.4.1 could write an invalid `:- dynamic(...)` declaration when a fact
argument contained `:` or `:-`. A later process may fail to mount that memory
with `LoadFailed`. The fix protects newly generated snapshots; it does not
rewrite snapshots already on disk.

Stop all zpm processes using the project before attempting a repair. Copy the
complete affected memory directory to a safe location and verify the copy:

```bash
memory_dir=".zpm/kb/feature_auth"  # Replace with the affected memory path
backup_dir="/safe/recovery/location/feature_auth-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"
cp -a "$memory_dir/." "$backup_dir/"
diff -qr "$memory_dir" "$backup_dir"
```

Inspect the affected snapshot for malformed `:- dynamic(...)` declarations
and compare them with the fact heads. For example, a snapshot containing
`adr(boundary, 'Domain', 'Keep std::fs outside domain').` needs the declaration
`:- dynamic(adr/3).`.

Repair only the generated declaration in a separate copy of the project.
Leave the fact clauses, other snapshots, `knowledge.pl`, and WAL unchanged.
Start zpm in that copy, query each affected predicate, and check that the
expected facts appear exactly once. If the copy mounts successfully, apply
the same declaration-only repair to the original snapshot while zpm remains
stopped, then restart and verify again. Keep the byte-for-byte backup for
rollback. Do not delete the knowledge-base directory: the active journal may
contain mutations made after the snapshot.
