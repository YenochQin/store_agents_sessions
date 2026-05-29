# Repository Guidelines

## Project Structure & Module Organization

This repository contains a Nushell-based backup, restore, and sync utility for Codex conversation data.

- `codex-chat.nu` is the main script and contains all subcommands and helper functions.
- `path-mapping.toml` stores cross-platform path mappings used during restore/remap operations.
- `codex-chat-sync/` is a git-ignored backup output directory; keep only `.gitkeep` under version control.
- `README.md` documents user-facing workflows and examples.
- `CLAUDE.md` captures implementation notes and safety invariants for agent work.

## Build, Test, and Development Commands

There is no build step. Run the script directly with Nushell:

```bash
nu codex-chat.nu backup
nu codex-chat.nu restore --backup-path ./codex-chat-sync/YYYYMMDD-HHMMSS --merge-folders
nu codex-chat.nu remap-paths --dry-run
nu codex-chat.nu compress
```

For development validation, prefer a disposable Codex home instead of live `~/.codex` data:

```bash
nu codex-chat.nu backup --codex-home ./tmp/codex-home
```

## Coding Style & Naming Conventions

- Use Nushell idioms and keep shared logic in module-level `def` helpers.
- Name subcommands and flags in kebab case, for example `merge-index`, `remap-paths`, and `--backup-path`.
- Use descriptive variable and function names; avoid single-letter names.
- Keep changes focused and preserve existing safety behavior around backup, restore, and SQLite merging.
- Update `README.md` when command behavior, flags, or restore semantics change.

## Testing Guidelines

No formal test suite is currently configured. Validate manually with throwaway fixtures and dry runs.

- Use `--dry-run` for path remapping checks before writing files.
- Test restore modes with temporary backup folders before touching real Codex data.
- Confirm safety backups are created before restore operations.
- Do not test destructive restore behavior against a live `~/.codex` directory.

## Commit & Pull Request Guidelines

Recent commits use short Conventional Commit-style messages, such as `feat: sync state_*.sqlite` and `fix: never file-replace the App sqlite across machines`. Follow that pattern where practical.

Pull requests should include:

- A concise summary of the behavior change.
- Manual validation commands and their results.
- Notes about any restore, migration, or data-safety implications.
- Linked issues when applicable.

## Security & Configuration Tips

- Never commit real backup archives, session data, or local Codex state files.
- Keep `codex-chat-sync/` contents ignored except `.gitkeep`.
- Treat restore logic as data-sensitive: preserve safety backups, deduplication, path remapping, and SQLite row-merge behavior.
