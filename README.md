# Codex Chat Backup & Sync

Nushell helper for backing up, restoring, and moving Codex App conversation data between machines.

The script focuses on conversation state, not the whole `~/.codex` directory. It copies the files needed for chat history while avoiding auth tokens, logs, temporary files, and sandbox data.

## What Gets Synced

`codex-chat.nu backup` stores:

| Path | Purpose |
|------|---------|
| `sessions/` | Active rollout JSONL conversation files |
| `archived_sessions/` | Archived rollout JSONL conversation files |
| `session_index.jsonl` | Thread list metadata used by Codex/CLI history |
| `state_*.sqlite` | Codex App thread index/state database, copied with WAL checkpointing |

Do not sync the entire `~/.codex` directory. Files such as `auth.json`, `config.toml`, logs, sqlite logs, temp folders, and sandbox folders should remain local to each machine.

## Files In This Repo

| File | Purpose |
|------|---------|
| `codex-chat.nu` | Main backup, restore, remap, discovery, and compression script |
| `path-mapping.toml` | Cross-platform project path mapping |
| `codex-chat-sync/` | Git-ignored backup output directory |
| `AGENTS.md` | Repository guidance for coding agents |
| `CLAUDE.md` | Additional implementation notes |

## Requirements

- Nushell installed as `nu`
- Codex App closed before backup or restore
- `tar` on Windows or `zip`/`unzip` on macOS/Linux when using zip backups

The script refuses to run while a Codex process is detected unless you pass `--ignore-running-codex`.

## Quick Start

Create a folder backup:

```nu
nu codex-chat.nu backup
```

Create a zip backup:

```nu
nu codex-chat.nu backup --zip
```

Restore from a backup folder and only add missing files:

```nu
nu codex-chat.nu restore --backup-path ./codex-chat-sync/YYYYMMDD-HHMMSS --merge-folders
```

Restore from a zip and replace local chat folders:

```nu
nu codex-chat.nu restore --backup-path ./codex-chat-sync/YYYYMMDD-HHMMSS.zip --replace-folders
```

Restart Codex App after restore.

## Backup Layout

Backups are created under `codex-chat-sync/` next to the script:

```text
codex-chat-sync/
  20260528-103000/
    sessions/
    archived_sessions/
    session_index.jsonl
    state_5.sqlite
  20260528-103000.zip
  before-restore-20260528-120000/
    ...
```

Restore always creates a `before-restore-*` safety backup before changing local Codex data.

## Restore Modes

| Mode | Chat folders | `session_index.jsonl` |
|------|--------------|-----------------------|
| default | Fails if destination folders already exist | Merge deduplicated lines |
| `--merge-folders` | Copies only missing files | Merge deduplicated lines |
| `--replace-folders` | Replaces `sessions/` and `archived_sessions/` | Replace entirely |

For most cross-machine syncs, use `--merge-folders` when combining histories and `--replace-folders` when the backup should become the target machine's source of truth.

## App SQLite Handling

Codex App also keeps a thread index in `state_*.sqlite`. This script backs it up, but restore does not replace another machine's sqlite file wholesale.

Instead, restore merges selected thread-related tables into the local App database:

```text
threads
thread_dynamic_tools
stage1_outputs
thread_spawn_edges
```

This avoids breaking Codex App migrations, which can be build-specific. If a local `state_*.sqlite` does not exist yet, launch Codex once to create it, then run restore again.

## Path Mapping

Session files and App thread rows store project paths in `cwd`. A backup written on macOS may contain paths like `/Users/you/...`, while Windows needs `D:\...`. Without remapping, restored threads may exist on disk but not appear under the expected project.

Configure `path-mapping.toml`:

```toml
[paths.projectfiles]
windows = 'D:\ProjectFiles'
macos = "/Users/yiqin/Documents/ProjectFiles"

[paths.phd-paper]
windows = 'E:\LaTeX\paper\phd_paper\draft'
macos = "/Users/yiqin/Documents/LaTeX/paper/phd_paper/draft"
```

Windows paths should use TOML single-quoted strings so backslashes do not need escaping.

Restore automatically runs path remapping when `path-mapping.toml` exists. You can also run it manually:

```nu
nu codex-chat.nu remap-paths --dry-run
nu codex-chat.nu remap-paths
```

## Discover Missing Mappings

Use `discover-paths` to scan current Codex records and find project paths not covered by `path-mapping.toml`:

```nu
nu codex-chat.nu discover-paths
```

Append suggested TOML blocks with placeholders:

```nu
nu codex-chat.nu discover-paths --write
```

Then edit the generated `FILL_IN` values before running restore/remap again.

## Merge Index Only

Append missing index entries without touching session folders:

```nu
nu codex-chat.nu merge-index --source-index ./codex-chat-sync/YYYYMMDD-HHMMSS/session_index.jsonl
```

Use `--destination-index` to target a non-default Codex home, and `--create-destination` if the destination file does not exist.

## Compress Old Backups

Zip backup folders older than 30 days:

```nu
nu codex-chat.nu compress
```

Remove original folders after zipping:

```nu
nu codex-chat.nu compress --remove-original
```

Change the age threshold:

```nu
nu codex-chat.nu compress --older-than-days 7
```

## Custom Locations

All commands default to `~/.codex` and `./codex-chat-sync`. Override them when testing or using a nonstandard setup:

```nu
nu codex-chat.nu backup --codex-home ./fixtures/codex-home --backup-root ./tmp/backups
nu codex-chat.nu restore --backup-path ./tmp/backups/20260528-103000 --codex-home ./fixtures/codex-home --merge-folders
nu codex-chat.nu remap-paths --codex-home ./fixtures/codex-home --mapping-file ./path-mapping.toml --dry-run
```

Prefer disposable folders when validating restore behavior.

## Recommended Sync Workflow

1. Close Codex App on the source machine.
2. Run `nu codex-chat.nu backup --zip`.
3. Sync or copy the zip via OneDrive, Dropbox, Syncthing, USB, or a private storage location.
4. Close Codex App on the target machine.
5. Run restore with `--merge-folders` or `--replace-folders`.
6. Restart Codex App.
7. If threads are missing, run `nu codex-chat.nu discover-paths` and update `path-mapping.toml`.

## Safety Notes

- `codex-chat-sync/` is intentionally git-ignored.
- Restore creates a safety backup before writing.
- Index merging is append-only and deduplicated by exact line equality.
- `state_*.sqlite` is merged row-by-row, not copied over another machine's database.
- Path remapping updates rollout first-line `payload.cwd` values and App sqlite thread paths.
- Archived sessions are backed up and restored along with active sessions.
