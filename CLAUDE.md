
This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Backup and restore scripts for Codex App conversation data (`~/.codex/sessions`, `~/.codex/archived_sessions`, `session_index.jsonl`). Two implementations: PowerShell (Windows) and Nushell (cross-platform). Backups are stored in timestamped directories under `codex-chat-sync/`.

## Architecture

- **PowerShell scripts** (`*.ps1`): Four scripts, each handling one operation (backup, restore, merge-index, compress). `Restore-CodexChat.ps1` calls `Merge-CodexSessionIndex.ps1` internally.
- **Nushell script** (`codex-chat.nu`): Single file with subcommands (`backup`, `restore`, `merge-index`, `compress`) that mirror the PowerShell scripts. All shared helpers are module-level `def` functions.
- **`codex-chat-sync/`**: Git-ignored directory holding timestamped backup folders. Intended to be synced via OneDrive/Dropbox/Syncthing.

Both implementations share the same safety invariants: check for running Codex process, create safety backup before restore, deduplicate JSONL index lines on merge, generate unique timestamped paths with collision avoidance.

## Common Operations

```bash
# PowerShell - backup
pwsh Backup-CodexChat.ps1

# PowerShell - restore with merge
pwsh Restore-CodexChat.ps1 -BackupPath "./codex-chat-sync/20260528-103000" -MergeFolders

# PowerShell - compress old backups
pwsh Compress-CodexChatBackups.ps1

# Nushell - backup
nu codex-chat.nu backup

# Nushell - restore with merge
nu codex-chat.nu restore --backup-path ./codex-chat-sync/20260528-103000 --merge-folders

# Nushell - compress old backups
nu codex-chat.nu compress
```

## Key Design Decisions

- Codex App must be closed before backup/restore (enforced by process check, overridable with `-IgnoreRunningCodex` / `--ignore-running-codex`).
- Restore always creates a safety backup first, stored under `codex-chat-sync/before-restore-*`.
- Index merge is append-only and deduplicated by exact line equality.
- Three restore modes: default (fail if destination exists), `-MergeFolders` (copy only missing files), `-ReplaceFolders` (delete and replace).
- No test suite exists. Validate changes by running scripts against a test `~/.codex` directory.
