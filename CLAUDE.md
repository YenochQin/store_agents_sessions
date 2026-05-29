
This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Backup and restore tool for Codex conversation data. Two indexes are kept in sync: the CLI's `~/.codex/session_index.jsonl` plus the rollout files under `~/.codex/sessions` and `~/.codex/archived_sessions`, and the Codex App's thread index `~/.codex/state_*.sqlite`. Backups are stored in timestamped directories under `codex-chat-sync/`.

## Architecture

- **Nushell script** (`codex-chat.nu`): Single file with subcommands (`backup`, `restore`, `merge-index`, `remap-paths`, `compress`). All shared helpers are module-level `def` functions. This is the only implementation; the earlier PowerShell scripts were removed.
- **`path-mapping.toml`**: Per-project `[paths.<name>]` entries with `windows`/`macos` absolute paths. Used to remap project `cwd` when restoring across machines. Longest-prefix match wins, so a project entry also covers its subdirectories.
- **`codex-chat-sync/`**: Git-ignored directory holding timestamped backup folders. Intended to be synced via OneDrive/Dropbox/Syncthing.

Safety invariants: check for running Codex process, create safety backup before restore (including `state_*.sqlite`), deduplicate JSONL index lines on merge, generate unique timestamped paths with collision avoidance.

## Common Operations

```bash
# backup (captures sessions, index, and state_*.sqlite)
nu codex-chat.nu backup

# restore with merge
nu codex-chat.nu restore --backup-path ./codex-chat-sync/20260528-103000 --merge-folders

# remap paths only (dry run)
nu codex-chat.nu remap-paths --dry-run

# compress old backups
nu codex-chat.nu compress
```

## Key Design Decisions

- Codex must be closed before backup/restore (enforced by process check, overridable with `--ignore-running-codex`).
- Restore always creates a safety backup first, stored under `codex-chat-sync/before-restore-*`.
- Index merge is append-only and deduplicated by exact line equality.
- Three restore modes apply to the session folders/index: default (fail if destination exists), `--merge-folders` (copy only missing files), `--replace-folders` (delete and replace).
- **The App db is always row-merged, never file-replaced** — regardless of the folder mode. `state_*.sqlite` carries build-specific `_sqlx_migrations` checksums; copying a foreign db makes Codex refuse to launch (`migration N ... has been modified`). The merge inserts thread rows (intersecting columns present in both dbs) into the local db, preserving its schema and migrations. If no local db exists, restore skips it and asks the user to launch Codex once to create it first.
- **Two indexes, one source of truth per client**: the CLI reads `session_index.jsonl`; the App reads `state_*.sqlite`. Both are kept in sync so either client sees the sessions.
- **Path remapping on restore**: `cwd` (in rollout JSONL and in `threads.cwd`) is remapped via `path-mapping.toml`; Windows extended-length `\\?\` prefixes are stripped before matching. `threads.rollout_path` is re-rooted onto the local codex home (split on the `.codex` segment), independent of the mapping file.
- The sqlite is backed up by checkpointing the WAL (`PRAGMA wal_checkpoint(TRUNCATE)`) then copying the single `.sqlite`; on checkpoint failure it falls back to copying `-wal`/`-shm` too.
- No test suite exists. Validate changes by running against a throwaway `--codex-home`, never the live `~/.codex`.
