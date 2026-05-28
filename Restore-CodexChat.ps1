[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$BackupPath,

    [string]$CodexHome = (Join-Path $HOME ".codex"),
    [string]$SafetyBackupRoot = (Join-Path $PSScriptRoot "codex-chat-sync"),
    [switch]$MergeFolders,
    [switch]$ReplaceFolders,
    [switch]$IgnoreRunningCodex
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-CodexProcess {
    try {
        return @(Get-Process | Where-Object { $_.ProcessName -match "codex" }).Count -gt 0
    }
    catch {
        return $false
    }
}

function New-UniquePath {
    param(
        [string]$Root,
        [string]$Prefix
    )

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $path = Join-Path $Root ("{0}-{1}" -f $Prefix, $timestamp)
    $counter = 1

    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $Root ("{0}-{1}-{2:D2}" -f $Prefix, $timestamp, $counter)
        $counter++
    }

    return $path
}

function Copy-IfExists {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (Test-Path -LiteralPath $Source) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Recurse
    }
}

function Copy-MissingTreeItems {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot
    )

    New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null

    $sourceRootFull = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $destinationRootFull = [System.IO.Path]::GetFullPath($DestinationRoot)

    Get-ChildItem -LiteralPath $sourceRootFull -Recurse -Force | ForEach-Object {
        $relativePath = $_.FullName.Substring($sourceRootFull.Length).TrimStart(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
        $targetPath = Join-Path $destinationRootFull $relativePath

        if ($_.PSIsContainer) {
            New-Item -ItemType Directory -Force -Path $targetPath | Out-Null
            return
        }

        if (-not (Test-Path -LiteralPath $targetPath)) {
            $targetDirectory = Split-Path -Parent $targetPath
            New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $targetPath
        }
    }
}

$backupFull = [System.IO.Path]::GetFullPath($BackupPath)
$codexHomeFull = [System.IO.Path]::GetFullPath($CodexHome)
$safetyRootFull = [System.IO.Path]::GetFullPath($SafetyBackupRoot)

$tempExtractDir = $null

try {
    if ((Test-Path -LiteralPath $backupFull -PathType Leaf) -and ($backupFull -match '\.zip$')) {
        $tempExtractDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-chat-restore-" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tempExtractDir | Out-Null
        Expand-Archive -LiteralPath $backupFull -DestinationPath $tempExtractDir -Force

        $extractedDirs = @(Get-ChildItem -LiteralPath $tempExtractDir -Directory)
        $backupFull = if ($extractedDirs.Count -eq 1) {
            $extractedDirs[0].FullName
        }
        else {
            $tempExtractDir
        }
    }

    $backupSessions = Join-Path $backupFull "sessions"
    $backupArchivedSessions = Join-Path $backupFull "archived_sessions"
    $backupIndex = Join-Path $backupFull "session_index.jsonl"

    if ((Test-CodexProcess) -and -not $IgnoreRunningCodex) {
        throw "Codex appears to be running. Close Codex App before restore, or rerun with -IgnoreRunningCodex if you accept the risk."
    }

    if ($MergeFolders -and $ReplaceFolders) {
        throw "Use only one mode: -MergeFolders or -ReplaceFolders."
    }

    foreach ($requiredPath in @($backupSessions, $backupArchivedSessions, $backupIndex)) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Backup is incomplete. Missing: $requiredPath"
        }
    }

    New-Item -ItemType Directory -Force -Path $codexHomeFull | Out-Null
    New-Item -ItemType Directory -Force -Path $safetyRootFull | Out-Null

    $safetyBackup = New-UniquePath -Root $safetyRootFull -Prefix "before-restore"
    $localSessions = Join-Path $codexHomeFull "sessions"
    $localArchivedSessions = Join-Path $codexHomeFull "archived_sessions"
    $localIndex = Join-Path $codexHomeFull "session_index.jsonl"

    if ($PSCmdlet.ShouldProcess($safetyBackup, "Create safety backup of current Codex chat files")) {
        New-Item -ItemType Directory -Force -Path $safetyBackup | Out-Null
        Copy-IfExists -Source $localSessions -Destination (Join-Path $safetyBackup "sessions")
        Copy-IfExists -Source $localArchivedSessions -Destination (Join-Path $safetyBackup "archived_sessions")
        Copy-IfExists -Source $localIndex -Destination (Join-Path $safetyBackup "session_index.jsonl")
        Write-Host "Safety backup created: $safetyBackup"
    }

    if (-not $MergeFolders) {
        foreach ($targetFolder in @($localSessions, $localArchivedSessions)) {
            if ((Test-Path -LiteralPath $targetFolder) -and -not $ReplaceFolders) {
                throw "Destination folder already exists: $targetFolder. Safety backup has been created. Rerun with -MergeFolders to add missing files or -ReplaceFolders to replace Codex chat folders."
            }
        }
    }

    if ($PSCmdlet.ShouldProcess($codexHomeFull, "Restore Codex chat folders and merge session index")) {
        if ($MergeFolders) {
            Copy-MissingTreeItems -SourceRoot $backupSessions -DestinationRoot $localSessions
            Copy-MissingTreeItems -SourceRoot $backupArchivedSessions -DestinationRoot $localArchivedSessions
        }
        elseif ($ReplaceFolders) {
            foreach ($targetFolder in @($localSessions, $localArchivedSessions)) {
                if (Test-Path -LiteralPath $targetFolder) {
                    Remove-Item -LiteralPath $targetFolder -Recurse -Force
                }
            }

            Copy-Item -LiteralPath $backupSessions -Destination $localSessions -Recurse
            Copy-Item -LiteralPath $backupArchivedSessions -Destination $localArchivedSessions -Recurse
        }
        else {
            Copy-Item -LiteralPath $backupSessions -Destination $localSessions -Recurse
            Copy-Item -LiteralPath $backupArchivedSessions -Destination $localArchivedSessions -Recurse
        }

        if (-not (Test-Path -LiteralPath $localIndex)) {
            New-Item -ItemType File -Path $localIndex | Out-Null
        }

        & (Join-Path $PSScriptRoot "Merge-CodexSessionIndex.ps1") -SourceIndex $backupIndex -DestinationIndex $localIndex
        Write-Host "Restore completed into: $codexHomeFull"
    }
}
finally {
    if ($tempExtractDir -and (Test-Path -LiteralPath $tempExtractDir)) {
        Remove-Item -LiteralPath $tempExtractDir -Recurse -Force
    }
}
