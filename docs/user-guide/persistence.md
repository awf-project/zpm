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

```bash
# Call via MCP
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "save_snapshot",
    "arguments": {
      "snapshot_name": "backup_2026_04_13"
    }
  }
}
```

After a snapshot:
- The journal is truncated to prevent unbounded growth
- You can restore to this exact state later
- The snapshot uses human-readable Prolog source format

## List Available Snapshots

Query all available snapshots to see what restore points exist:

```bash
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

```bash
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "restore_snapshot",
    "arguments": {
      "snapshot_name": "backup_2026_04_13"
    }
  }
}
```

The restore process:
1. Loads the snapshot, replacing the current knowledge base
2. Replays all journal entries recorded after the snapshot
3. Returns to the exact state including any facts added since the snapshot

This enables point-in-time recovery without losing recent changes.

## Monitor Persistence Status

Check the status of your persistence layer (journal size, last snapshot, operational mode):

```bash
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
- Manual fact correction if needed
- Integration with standard Prolog tools
