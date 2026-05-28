# Codex Chat Backup Scripts

These scripts back up and restore only Codex App conversation files:

- Windows: `%USERPROFILE%\.codex\sessions`
- Windows: `%USERPROFILE%\.codex\archived_sessions`
- Windows: `%USERPROFILE%\.codex\session_index.jsonl`
- macOS/Linux: `~/.codex/sessions`
- macOS/Linux: `~/.codex/archived_sessions`
- macOS/Linux: `~/.codex/session_index.jsonl`

They intentionally do not copy the whole `.codex` directory.

## Scripts

- `Backup-CodexChat.ps1` creates a timestamped backup under this directory's `codex-chat-sync` folder.
- `Restore-CodexChat.ps1` restores a selected backup and first creates a safety backup of the current local records.
- `Merge-CodexSessionIndex.ps1` appends missing `session_index.jsonl` entries without overwriting the destination index.
- `Compress-CodexChatBackups.ps1` creates zip archives for older timestamped backup folders.
- `codex-chat.nu` is the cross-platform Nushell version for Windows and macOS.

## Local Sync Directory

The default sync and backup root is the `codex-chat-sync` directory next to these scripts.

In this workspace that is:

```text
D:\ProjectFiles\store_agents_sessions\codex-chat-sync
```

Each backup is stored in a timestamped child directory:

```text
codex-chat-sync\
  20260528-103000\
    sessions\
    archived_sessions\
    session_index.jsonl
```

On macOS, put `codex-chat.nu` and `codex-chat-sync` in the same folder. The script will use that local `codex-chat-sync` folder automatically.

You can sync this `codex-chat-sync` directory with OneDrive, Dropbox, Syncthing, or a private Git repository. Do not sync the entire `.codex` directory.

## Daily Backup

Close Codex App first, then run:

```powershell
.\Backup-CodexChat.ps1
```

Nushell:

```nu
nu codex-chat.nu backup
```

Create a zip copy at the same time:

```powershell
.\Backup-CodexChat.ps1 -Zip
```

Nushell:

```nu
nu codex-chat.nu backup --zip
```

If you need to back up from a custom Codex home:

```powershell
.\Backup-CodexChat.ps1 -CodexHome "D:\Somewhere\.codex"
```

Nushell:

```nu
nu codex-chat.nu backup --codex-home "D:\Somewhere\.codex"
```

macOS example:

```nu
nu codex-chat.nu backup --codex-home ~/.codex
```

## Restore Or Migrate

Close Codex App first.

Restore folders and merge index lines from a backup:

```powershell
.\Restore-CodexChat.ps1 -BackupPath ".\codex-chat-sync\20260528-103000"
```

If this computer already has Codex records, merge missing session files and append missing index lines:

```powershell
.\Restore-CodexChat.ps1 -BackupPath ".\codex-chat-sync\20260528-103000" -MergeFolders
```

Nushell:

```nu
nu codex-chat.nu restore --backup-path ./codex-chat-sync/20260528-103000 --merge-folders
```

By default the restore script refuses to replace existing `sessions` and `archived_sessions` folders. To replace them after the safety backup is made:

```powershell
.\Restore-CodexChat.ps1 -BackupPath ".\codex-chat-sync\20260528-103000" -ReplaceFolders
```

Nushell:

```nu
nu codex-chat.nu restore --backup-path ./codex-chat-sync/20260528-103000 --replace-folders
```

## Merge Only The Index

```powershell
.\Merge-CodexSessionIndex.ps1 `
  -SourceIndex ".\codex-chat-sync\20260528-103000\session_index.jsonl" `
  -DestinationIndex "$HOME\.codex\session_index.jsonl"
```

Nushell:

```nu
nu codex-chat.nu merge-index --source-index ./codex-chat-sync/20260528-103000/session_index.jsonl
```

## Monthly Compression

Zip backup folders older than 30 days:

```powershell
.\Compress-CodexChatBackups.ps1
```

Remove folders after their zip is created:

```powershell
.\Compress-CodexChatBackups.ps1 -RemoveOriginal
```

Nushell:

```nu
nu codex-chat.nu compress --remove-original
```

## Syncing

Sync `codex-chat-sync` with OneDrive, Dropbox, Syncthing, or a private Git repository. Do not sync the entire `.codex` directory.
