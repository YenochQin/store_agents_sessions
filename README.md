# Codex Chat Backup & Sync

Backup, restore, and sync [Codex App](https://codex.openai.com/) conversation data across machines. Two implementations are provided: **PowerShell** (Windows) and **Nushell** (cross-platform).

Only conversation files are backed up -- the scripts intentionally skip the rest of `~/.codex`.

| File | Platform |
|------|----------|
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
| `codex-chat.nu` | Nushell equivalent with `backup`, `restore`, `merge-index`, `compress` subcommands |

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

```powershell
# PowerShell -- default (fails if destination folders exist)
.\Restore-CodexChat.ps1 -BackupPath ".\codex-chat-sync\20260528-103000"

# Merge missing files into existing data
.\Restore-CodexChat.ps1 -BackupPath ".\codex-chat-sync\20260528-103000" -MergeFolders

# Replace existing folders entirely
.\Restore-CodexChat.ps1 -BackupPath ".\codex-chat-sync\20260528-103000" -ReplaceFolders
```

```nu
# Nushell
nu codex-chat.nu restore --backup-path ./codex-chat-sync/20260528-103000 --merge-folders
nu codex-chat.nu restore --backup-path ./codex-chat-sync/20260528-103000 --replace-folders
```

A safety backup (`before-restore-*`) is always created before any restore operation.

## Restore Modes

| Mode | Behavior |
|------|----------|
| Default | Fails if `sessions/` or `archived_sessions/` already exist at the destination |
| `-MergeFolders` / `--merge-folders` | Copies only files that don't already exist locally |
| `-ReplaceFolders` / `--replace-folders` | Deletes existing folders and replaces them from backup |

All three modes merge `session_index.jsonl` by appending deduplicated lines.

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
- Timestamped paths include a counter suffix to avoid collisions.
