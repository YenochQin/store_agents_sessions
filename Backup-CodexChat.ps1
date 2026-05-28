[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CodexHome = (Join-Path $HOME ".codex"),
    [string]$BackupRoot = (Join-Path $PSScriptRoot "codex-chat-sync"),
    [switch]$Zip,
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

function New-UniqueBackupPath {
    param([string]$Root)

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $path = Join-Path $Root $timestamp
    $counter = 1

    while (Test-Path -LiteralPath $path) {
        $path = Join-Path $Root ("{0}-{1:D2}" -f $timestamp, $counter)
        $counter++
    }

    return $path
}

function Assert-SourcePath {
    param(
        [string]$Path,
        [string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing Codex $Description path: $Path"
    }
}

$codexHomeFull = [System.IO.Path]::GetFullPath($CodexHome)
$backupRootFull = [System.IO.Path]::GetFullPath($BackupRoot)

$sessionsPath = Join-Path $codexHomeFull "sessions"
$archivedSessionsPath = Join-Path $codexHomeFull "archived_sessions"
$indexPath = Join-Path $codexHomeFull "session_index.jsonl"

if ((Test-CodexProcess) -and -not $IgnoreRunningCodex) {
    throw "Codex appears to be running. Close Codex App before backup, or rerun with -IgnoreRunningCodex if you accept the risk."
}

Assert-SourcePath -Path $sessionsPath -Description "sessions"
Assert-SourcePath -Path $archivedSessionsPath -Description "archived_sessions"
Assert-SourcePath -Path $indexPath -Description "session_index.jsonl"

New-Item -ItemType Directory -Force -Path $backupRootFull | Out-Null
$destination = New-UniqueBackupPath -Root $backupRootFull

if ($PSCmdlet.ShouldProcess($destination, "Create Codex chat backup")) {
    New-Item -ItemType Directory -Force -Path $destination | Out-Null

    Copy-Item -LiteralPath $sessionsPath -Destination (Join-Path $destination "sessions") -Recurse
    Copy-Item -LiteralPath $archivedSessionsPath -Destination (Join-Path $destination "archived_sessions") -Recurse
    Copy-Item -LiteralPath $indexPath -Destination (Join-Path $destination "session_index.jsonl")

    if ($Zip) {
        $zipPath = "$destination.zip"
        Compress-Archive -LiteralPath $destination -DestinationPath $zipPath -Force
        Remove-Item -LiteralPath $destination -Recurse -Force
        Write-Host "Backup created: $zipPath"
    }
    else {
        Write-Host "Backup created: $destination"
    }
}
