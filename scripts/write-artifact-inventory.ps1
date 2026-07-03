param(
    [string]$OutputPath
)

# Load DX config
$ErrorActionPreference = "Continue"
$dxConfig = & {
    $modulePath = Join-Path $PSScriptRoot "dx-config.psm1"
    if (Test-Path $modulePath) {
        Import-Module $modulePath -Force -ErrorAction SilentlyContinue | Out-Null
        $cfg = Get-DxConfig
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $cfg.SrDir) -ErrorAction SilentlyContinue
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $cfg.ResolvePath("cache")) -ErrorAction SilentlyContinue
        $cfg
    } else { $null }
}
$ErrorActionPreference = "Stop"
$root = if ($dxConfig) { $dxConfig.Root } else { Split-Path -Parent $PSScriptRoot }
$manifestRoot = Join-Path $root '.dx\manifests'
$artifactNames = @('node_modules', 'target', 'target-debug', '.next', 'dist', 'coverage', '.cache', '.tmp', '.turbo', '.pytest_cache', '__pycache__')

if (-not $OutputPath) {
    New-Item -ItemType Directory -Path $manifestRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path $manifestRoot "artifact-inventory-$stamp.jsonl"
}

function Test-ReparsePoint {
    param([Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item)
    return [bool](($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)
}

function Get-DirectFileBytes {
    param([Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$Directory)

    $bytes = 0
    foreach ($file in Get-ChildItem -LiteralPath $Directory.FullName -Force -File -ErrorAction SilentlyContinue) {
        $bytes += $file.Length
    }

    return $bytes
}

function Write-InventoryRow {
    param(
        [Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$Directory,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $isRepo = Test-Path -LiteralPath (Join-Path $Directory.FullName '.git')
    $isReparsePoint = Test-ReparsePoint -Item $Directory
    $directChildren = @(Get-ChildItem -LiteralPath $Directory.FullName -Force -ErrorAction SilentlyContinue).Count
    $backupClass = if ($isRepo) { 'git-remote' } elseif ($Reason -eq 'excluded-artifact-name') { 'exclude' } else { 'manifest-only' }

    [pscustomobject]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToString('s')
        path = $Directory.FullName
        name = $Directory.Name
        reason = $Reason
        isGitRepository = $isRepo
        isReparsePoint = $isReparsePoint
        directChildCount = $directChildren
        directFileBytes = Get-DirectFileBytes -Directory $Directory
        backupClass = $backupClass
        deleteApproved = $false
    } | ConvertTo-Json -Compress -Depth 5 | Add-Content -LiteralPath $OutputPath
}

foreach ($folder in Get-ChildItem -LiteralPath $root -Force -Directory | Sort-Object FullName) {
    if ($folder.Name -eq '.git') {
        continue
    }

    $reason = if ($folder.Name -in $artifactNames) { 'excluded-artifact-name' } elseif ($folder.Name -eq 'trash') { 'archive-quarantine' } elseif ($folder.Name -eq '.dx') { 'hub-runtime-state' } else { 'root-folder' }
    Write-InventoryRow -Directory $folder -Reason $reason

    if ((Test-Path -LiteralPath (Join-Path $folder.FullName '.git')) -and -not (Test-ReparsePoint -Item $folder)) {
        foreach ($child in Get-ChildItem -LiteralPath $folder.FullName -Force -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -in $artifactNames } | Sort-Object FullName) {
            Write-InventoryRow -Directory $child -Reason 'excluded-artifact-name'
        }
    }
}

Write-Output $OutputPath

# Write .sr for serializer daemon
if ($dxConfig) {
    Write-DxSr -Path (Join-Path $dxConfig.SrDir "write-artifact-inventory.sr") -Entries @{
        tool = "write-artifact-inventory"
        action = "run"
        status = "ok"
    }
}
