[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceIndex,

    [string]$DestinationIndex = (Join-Path (Join-Path $HOME ".codex") "session_index.jsonl"),

    [switch]$CreateDestination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-JsonlLines {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    return @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_.Trim().Length -gt 0 })
}

$sourceFull = [System.IO.Path]::GetFullPath($SourceIndex)
$destinationFull = [System.IO.Path]::GetFullPath($DestinationIndex)
$destinationDirectory = Split-Path -Parent $destinationFull

if (-not (Test-Path -LiteralPath $sourceFull)) {
    throw "Source index does not exist: $sourceFull"
}

if (-not (Test-Path -LiteralPath $destinationDirectory)) {
    throw "Destination directory does not exist: $destinationDirectory"
}

if (-not (Test-Path -LiteralPath $destinationFull)) {
    if (-not $CreateDestination) {
        throw "Destination index does not exist: $destinationFull. Rerun with -CreateDestination to create it."
    }

    if ($PSCmdlet.ShouldProcess($destinationFull, "Create empty destination index")) {
        New-Item -ItemType File -Path $destinationFull | Out-Null
    }
}

$existingLines = Read-JsonlLines -Path $destinationFull
$existingSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($line in $existingLines) {
    [void]$existingSet.Add($line)
}

$sourceLines = Read-JsonlLines -Path $sourceFull
$linesToAppend = [System.Collections.Generic.List[string]]::new()

foreach ($line in $sourceLines) {
    if ($existingSet.Add($line)) {
        $linesToAppend.Add($line)
    }
}

if ($linesToAppend.Count -eq 0) {
    Write-Host "No new index lines to merge."
    return
}

if ($PSCmdlet.ShouldProcess($destinationFull, "Append $($linesToAppend.Count) unique session_index.jsonl lines")) {
    Add-Content -LiteralPath $destinationFull -Value $linesToAppend -Encoding UTF8
    Write-Host "Merged $($linesToAppend.Count) new index lines into: $destinationFull"
}
