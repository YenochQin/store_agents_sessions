[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$BackupRoot = (Join-Path $PSScriptRoot "codex-chat-sync"),
    [int]$OlderThanDays = 30,
    [switch]$RemoveOriginal
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$backupRootFull = [System.IO.Path]::GetFullPath($BackupRoot)

if (-not (Test-Path -LiteralPath $backupRootFull)) {
    throw "Backup root does not exist: $backupRootFull"
}

$cutoff = (Get-Date).AddDays(-1 * $OlderThanDays)
$backupFolders = Get-ChildItem -LiteralPath $backupRootFull -Directory |
    Where-Object {
        $_.Name -match "^\d{8}-\d{6}(-\d{2})?$" -and
        $_.LastWriteTime -lt $cutoff
    }

if (@($backupFolders).Count -eq 0) {
    Write-Host "No backup folders older than $OlderThanDays days found."
    return
}

foreach ($folder in $backupFolders) {
    $zipPath = "$($folder.FullName).zip"

    if ($PSCmdlet.ShouldProcess($zipPath, "Compress backup folder $($folder.FullName)")) {
        Compress-Archive -LiteralPath $folder.FullName -DestinationPath $zipPath -Force
        Write-Host "Zip created: $zipPath"
    }

    if ($RemoveOriginal) {
        if ($PSCmdlet.ShouldProcess($folder.FullName, "Remove original backup folder after compression")) {
            Remove-Item -LiteralPath $folder.FullName -Recurse -Force
            Write-Host "Removed original folder: $($folder.FullName)"
        }
    }
}
