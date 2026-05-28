# Codex Chat Backup & Sync

Backup, restore, and sync [Codex App](https://codex.openai.com/) conversation data across machines. Two implementations are provided: **PowerShell** (Windows) and **Nushell** (cross-platform).

Only conversation files are backed up -- the scripts intentionally skip the rest of `~/.codex`.

| File | Description |
|------|-------------|
| `sessions/` | Active conversation sessions |
| `archived_sessions/` | Archived conversations |
| `session_index.jsonl` | Session metadata index |

## Scripts

| Script | Description |
|--------|-------------|
| `Backup-CodexChat.ps1` | Create a timestamped backup |
| `Restore-CodexChat.ps1` | Restore from a backup (creates a safety backup first) |
| `Merge-CodexSessionIndex.ps1` | Append missing index entries without overwriting |
| `Compress-CodexChatBackups.ps1` | Zip backup folders older than N days |
| `codex-chat.nu` | Nushell equivalent with `backup`, `restore`, `merge-index`, `remap-paths`, `compress` subcommands |
| `path-mapping.jsonl` | Path mapping config for cross-platform migration |

## Quick Start

Close Codex App before running any script.

### Backup

```powershell
# PowerShell
.\Backup-CodexChat.ps1

# With zip archive
.\Backup-CodexChat.ps1 -Zip
```

```nu
# Nushell
nu codex-chat.nu backup

# With zip archive
nu codex-chat.nu backup --zip
```

### Restore

Restore accepts both directories and `.zip` archives as `--backup-path`.

```powershell
# PowerShell -- default (fails if destination folders exist)
.\Restore-CodexChat.ps1 -BackupPath ".\codex-chat-sync\20260528-103000"

# From a zip archive
.\Restore-CodexChat.ps1 -BackupPath ".\codex-chat-sync\20260528-103000.zip" -ReplaceFolders

# Merge missing files into existing data
.\Restore-CodexChat.ps1 -BackupPath ".\codex-chat-sync\20260528-103000" -MergeFolders

# Replace existing folders entirely
.\Restore-CodexChat.ps1 -BackupPath ".\codex-chat-sync\20260528-103000" -ReplaceFolders
```

```nu
# Nushell
nu codex-chat.nu restore --backup-path ./codex-chat-sync/20260528-103000 --merge-folders
nu codex-chat.nu restore --backup-path ./codex-chat-sync/20260528-103000 --replace-folders

# From a zip archive
nu codex-chat.nu restore --backup-path ./codex-chat-sync/20260528-103000.zip --replace-folders
```

A safety backup (`before-restore-*`) is always created before any restore operation.

## Restore Modes

| Mode | Folders | Index |
|------|---------|-------|
| Default | Fails if destination folders already exist | Merge (append deduplicated lines) |
| `-MergeFolders` / `--merge-folders` | Copies only files that don't already exist locally | Merge |
| `-ReplaceFolders` / `--replace-folders` | Deletes existing folders and replaces them from backup | Replace entirely |

## Cross-Platform Migration

Session files store the project path (`cwd`) from the originating machine. When migrating between macOS and Windows (or vice versa), the Codex app won't display restored conversations because the paths don't match. Use `remap-paths` to rewrite them.

### 1. Configure path mappings

Edit `path-mapping.jsonl` (one JSON object per line):

```jsonl
{"from":"/Users/yiqin/Documents/ProjectFiles","to":"D:\\ProjectFiles"}
{"from":"/Users/yiqin/Documents/PythonProjects","to":"D:\\PythonProjects"}
```

- `from`: the source machine path prefix
- `to`: the corresponding path on the target machine
- Longest prefix matches first
- Remove lines for paths with no local equivalent (those sessions keep their original paths)

### 2. Preview and apply

```nu
# Preview changes without modifying files
nu codex-chat.nu remap-paths --dry-run

# Apply the remapping
nu codex-chat.nu remap-paths

# Use a custom mapping file
nu codex-chat.nu remap-paths --mapping-file /path/to/mapping.jsonl
```

### Full migration workflow

```bash
# On source machine: backup
nu codex-chat.nu backup --zip

# Transfer the zip via OneDrive / Dropbox / Syncthing / USB

# On target machine: restore + remap
nu codex-chat.nu restore --backup-path ./codex-chat-sync/YYYYMMDD-HHMMSS.zip --replace-folders
nu codex-chat.nu remap-paths --dry-run
nu codex-chat.nu remap-paths

# Restart Codex App
```

## Merge Index Only

Append missing session index entries without touching session folders:

```powershell
.\Merge-CodexSessionIndex.ps1 `
  -SourceIndex ".\codex-chat-sync\20260528-103000\session_index.jsonl" `
  -DestinationIndex "$HOME\.codex\session_index.jsonl"
```

```nu
nu codex-chat.nu merge-index --source-index ./codex-chat-sync/20260528-103000/session_index.jsonl
```

## Compress Old Backups

Zip backup folders older than 30 days (default):

```powershell
.\Compress-CodexChatBackups.ps1

# Remove original folders after zipping
.\Compress-CodexChatBackups.ps1 -RemoveOriginal
```

```nu
nu codex-chat.nu compress
nu codex-chat.nu compress --remove-original
```

## Custom Codex Home

Both implementations default to `~/.codex`. Override with:

```powershell
.\Backup-CodexChat.ps1 -CodexHome "D:\Somewhere\.codex"
```

```nu
nu codex-chat.nu backup --codex-home /path/to/.codex
```

## Backup Storage Layout

Backups are stored in `codex-chat-sync/` next to the scripts, using timestamped directories with collision avoidance:

```
codex-chat-sync/
  20260528-103000/
    sessions/
    archived_sessions/
    session_index.jsonl
  20260528-103000.zip
  before-restore-20260528-120000/
    ...
```

## Syncing Across Machines

Sync the `codex-chat-sync/` directory using OneDrive, Dropbox, Syncthing, or a private Git repository. Do **not** sync the entire `~/.codex` directory.

## Safety

- Scripts check for a running Codex process and refuse to proceed unless `--ignore-running-codex` / `-IgnoreRunningCodex` is passed.
- Restore always creates a safety backup before modifying local data.
- Index merging is append-only and deduplicated by exact line equality.
- `-ReplaceFolders` replaces the index entirely (no dangling entries from the previous state).
- Timestamped paths include a counter suffix to avoid collisions.
