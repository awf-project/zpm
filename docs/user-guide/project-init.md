---
title: "Project Initialization"
---


Before using `zpm serve`, you must initialize a project directory with the `.zpm/` structure.

## Quick Start

Initialize your project:

```bash
cd /path/to/your/project
zpm init
```

Verify the structure was created:

```bash
ls -la .zpm/
# Output:
# drwxr-xr-x  kb/
# drwxr-xr-x  data/
# -rw-r--r--  .gitignore
```

Start the server:

```bash
zpm serve
```

## What `.zpm/` Contains

The `.zpm/` directory is divided into two parts:

| Directory | Purpose | Version Control |
|-----------|---------|-----------------|
| `.zpm/kb/` | Knowledge base: Prolog files and snapshots | ✓ Commit to Git |
| `.zpm/data/` | Runtime data: write-ahead journal and locks | ✗ Ignored by `.gitignore` |

### `.zpm/kb/` (Versionable)

Store your project's Prolog knowledge in this directory:

```
.zpm/kb/
  rules.pl              # Your custom rules
  domain.pl             # Domain-specific facts
  snapshot_001.pl       # Auto-generated snapshot
```

Files are automatically loaded on startup. Commit this directory to version control so team members have the same knowledge base.

### `.zpm/data/` (Ephemeral)

Contains runtime-only files that should not be committed:

```
.zpm/data/
  journal.wal           # Write-ahead log of all mutations
  snapshot.lock         # Snapshot creation lock
```

The `.gitignore` file automatically excludes this directory.

## Idempotent Initialization

Running `zpm init` multiple times is safe — it only creates the directory structure if it doesn't already exist:

```bash
zpm init    # Creates .zpm/, kb/, data/, .gitignore
zpm init    # Prints "Project already initialized" and exits with 0
```

## Per-Project Isolation

Each project has a fully independent knowledge base. Run multiple instances of `zpm serve` in different projects without cross-contamination:

```bash
# Terminal 1: Project A
cd ~/projects/project-a
zpm init
zpm serve

# Terminal 2: Project B
cd ~/projects/project-b
zpm init
zpm serve

# Facts asserted in project-a do not appear in project-b
```

## Automatic Discovery

Once initialized, `zpm serve` automatically finds `.zpm/` by walking up the directory tree. You can run `zpm serve` from any subdirectory:

```bash
cd ~/.local/share/project-a/src/components
zpm serve     # Finds .zpm/ in ~/.local/share/project-a/
```

If no `.zpm/` is found in the directory ancestry, `zpm serve` exits with a clear error:

```
error: no project directory found
hint: run 'zpm init' to initialize a project
```

## Team Workflow

1. **Initialize once per project:**
   ```bash
   git clone https://github.com/example/my-project.git
   cd my-project
   zpm init
   ```

2. **Commit the knowledge base:**
   ```bash
   # Add your Prolog rules
   echo "parent(alice, bob)." > .zpm/kb/facts.pl
   
   git add .zpm/kb/
   git commit -m "Add initial knowledge base"
   ```

3. **Clone and use in another environment:**
   ```bash
   git clone https://github.com/example/my-project.git
   cd my-project
   zpm serve     # Loads facts.pl automatically on startup
   ```

## Troubleshooting

**"no project directory found"**
- Run `zpm init` in your project root
- Ensure you're running `zpm serve` from within the project tree, not from an unrelated directory

**"Permission denied" during init**
- Check write permissions in the current directory: `ls -ld .`
- Ensure the filesystem is writable

**Degraded mode (in-memory only persistence)**
- `.zpm/data/` exists but is read-only
- Snapshots and journal operations fall back to in-memory storage (no persistence)
- Check directory permissions: `ls -ld .zpm/data/`

## See Also

- [CLI Reference](../reference/cli.md) — `zpm init` command details
- [Knowledge Base Persistence](persistence.md) — How snapshots and journals work
