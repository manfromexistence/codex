param(
    [string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'trash'),
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

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Path does not exist: $Path"
}

if (-not $OutputPath) {
    New-Item -ItemType Directory -Path $manifestRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path $manifestRoot "archive-manifest-$stamp.jsonl"
}

function Get-GitMarker {
    param([Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item)

    $marker = Join-Path $Item.FullName '.git'
    if (Test-Path -LiteralPath $marker -PathType Container) {
        return [pscustomobject]@{ Type = 'directory'; Target = $null; Stale = $false }
    }

    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        $firstLine = Get-Content -LiteralPath $marker -TotalCount 1 -ErrorAction SilentlyContinue
        $target = $null
        $stale = $false
        if ($firstLine -match '^gitdir:\s*(.+)$') {
            $target = $Matches[1]
            if (-not [System.IO.Path]::IsPathRooted($target)) {
                $target = Join-Path $Item.FullName $target
            }
            $stale = -not (Test-Path -LiteralPath $target)
        }

        return [pscustomobject]@{ Type = 'file'; Target = $target; Stale = $stale }
    }

    return [pscustomobject]@{ Type = 'none'; Target = $null; Stale = $false }
}

function Get-LinkTarget {
    param([Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item)

    if (-not (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)) {
        return $null
    }

    if ($Item.PSObject.Properties.Name -contains 'LinkTarget') {
        return $Item.LinkTarget
    }

    if ($Item.PSObject.Properties.Name -contains 'Target') {
        return ($Item.Target -join ';')
    }

    return $null
}

function Get-DirectFileBytes {
    param([Parameter(Mandatory = $true)][System.IO.DirectoryInfo]$Directory)

    $bytes = 0
    foreach ($file in Get-ChildItem -LiteralPath $Directory.FullName -Force -File -ErrorAction SilentlyContinue) {
        $bytes += $file.Length
    }

    return $bytes
}

function Get-ItemType {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item,
        [Parameter(Mandatory = $true)]$GitMarker,
        [string]$JunctionTarget
    )

    if ($JunctionTarget) {
        return 'junction-reference'
    }

    if ($GitMarker.Type -ne 'none') {
        return 'source-repo'
    }

    if ($Item.FullName.StartsWith((Join-Path $root 'trash'), [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'trash-payload'
    }

    return 'unknown'
}

$items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | Sort-Object FullName
foreach ($item in $items) {
    $gitMarker = if ($item.PSIsContainer) { Get-GitMarker -Item $item } else { [pscustomobject]@{ Type = 'none'; Target = $null; Stale = $false } }
    $junctionTarget = Get-LinkTarget -Item $item
    $directChildren = if ($item.PSIsContainer) { @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue).Count } else { 0 }
    $directFileBytes = if ($item.PSIsContainer) { Get-DirectFileBytes -Directory $item } else { $item.Length }
    $itemType = Get-ItemType -Item $item -GitMarker $gitMarker -JunctionTarget $junctionTarget
    $restoreCommand = if ($item.PSIsContainer) { "Copy-Item -LiteralPath '$($item.FullName)' -Destination '<restore-target>' -Recurse" } else { "Copy-Item -LiteralPath '$($item.FullName)' -Destination '<restore-target>'" }

    [pscustomobject]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToString('s')
        path = $item.FullName
        originalPath = $null
        archivePath = $null
        name = $item.Name
        itemType = $itemType
        lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
        directChildCount = $directChildren
        directFileBytes = $directFileBytes
        gitMarkerType = $gitMarker.Type
        gitdirTarget = $gitMarker.Target
        staleGitdirTarget = $gitMarker.Stale
        junctionTarget = $junctionTarget
        retentionClass = if ($itemType -eq 'source-repo') { 'source' } elseif ($itemType -eq 'trash-payload') { 'archive-review' } else { 'unknown' }
        backupClass = if ($itemType -eq 'source-repo') { 'git-remote' } else { 'manifest-only' }
        restoreCommand = $restoreCommand
        deleteApproved = $false
    } | ConvertTo-Json -Compress -Depth 5 | Add-Content -LiteralPath $OutputPath
}

Write-Output $OutputPath

# Write .sr for serializer daemon
if ($dxConfig) {
    Write-DxSr -Path (Join-Path $dxConfig.SrDir "write-archive-manifest.sr") -Entries @{
        tool = "write-archive-manifest"
        action = "run"
        status = "ok"
    }
}
