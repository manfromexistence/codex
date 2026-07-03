param(
    [switch]$Json
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

$folders = Get-ChildItem -LiteralPath $root -Force -Directory | Sort-Object Name
$rows = foreach ($folder in $folders) {
    if ($folder.Name -eq '.git') {
        continue
    }

    $path = $folder.FullName
    $kind = if ($folder.Name -in @('.dx', '.github', 'docs', 'scripts')) { 'Hub directory' } else { 'No git' }
    $branch = ''
    $remotes = @()
    $dirtyCount = $null
    $isBare = $false
    $isJunction = [bool](($folder.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint)

    $hasGitMetadata = (Test-Path -LiteralPath (Join-Path $path '.git'))
    if ($hasGitMetadata) {
        $inside = & git -C $path rev-parse --is-inside-work-tree 2>$null
        $bare = & git -C $path rev-parse --is-bare-repository 2>$null
    } else {
        $inside = ''
        $bare = ''
    }

    if ($hasGitMetadata -and $LASTEXITCODE -eq 0 -and (($inside -eq 'true') -or ($bare -eq 'true'))) {
        $isBare = $bare -eq 'true'
        $branch = & git -C $path branch --show-current 2>$null
        if (-not $branch) {
            $branch = & git -C $path symbolic-ref --short HEAD 2>$null
        }
        $remotes = @(& git -C $path remote 2>$null)
        $kind = if ($remotes.Count -gt 0) { 'Git connected' } else { 'Git no remote' }
        if (-not $isBare) {
            $dirtyCount = @(& git -C $path status --porcelain 2>$null).Count
        }
    }

    [pscustomobject]@{
        folder = $folder.Name
        kind = $kind
        branch = $branch
        remotes = $remotes
        dirtyCount = $dirtyCount
        isBare = $isBare
        isJunction = $isJunction
    }
}

$summary = [pscustomobject]@{
    root = $root
    generatedAt = (Get-Date).ToString('s')
    folderCount = $rows.Count
    gitConnected = @($rows | Where-Object { $_.kind -eq 'Git connected' }).Count
    noGit = @($rows | Where-Object { $_.kind -eq 'No git' }).Count
    hubDirectories = @($rows | Where-Object { $_.kind -eq 'Hub directory' }).Count
    junctions = @($rows | Where-Object { $_.isJunction }).Count
    dirtyRepos = @($rows | Where-Object { $_.dirtyCount -gt 0 } | Select-Object folder, branch, dirtyCount)
    folders = $rows
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 6
} else {
    $summary.folders | Format-Table folder, kind, branch, dirtyCount, isJunction -AutoSize
    ''
    "Folders: $($summary.folderCount)"
    "Git connected: $($summary.gitConnected)"
    "No Git: $($summary.noGit)"
    "Hub directories: $($summary.hubDirectories)"
    "Junctions: $($summary.junctions)"
    "Dirty repos: $(@($summary.dirtyRepos).Count)"
}

# Write .sr for serializer daemon
if ($dxConfig) {
    Write-DxSr -Path (Join-Path $dxConfig.SrDir "audit-hub.sr") -Entries @{
        tool = "audit-hub"
        action = "run"
        status = "ok"
    }
}
