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
$excludeNames = @('trash', 'node_modules', 'target', 'target-debug', '.next', 'dist', 'coverage', '.cache', '.tmp', '.turbo', '.pytest_cache', '__pycache__')
$includeRelativePaths = @(
    '.gitattributes',
    '.github',
    '.gitignore',
    '.rgignore',
    'AGENTS.md',
    'CHANGELOG.md',
    'CURRENT_STATUS.md',
    'DX.md',
    'DX_LANE_PASS_SYSTEM.md',
    'DX_MANAGER_MEMORY.md',
    'PLAN.md',
    'README.md',
    'TODO.md',
    '.dx\launch-workspace.toml',
    'docs\policies',
    'docs\superpowers',
    'dx',
    'scripts'
)

function Get-BackupClass {
    param([Parameter(Mandatory = $true)][string]$Path)

    $name = Split-Path -Leaf $Path
    if ($name -in $excludeNames) {
        return 'exclude'
    }

    $relative = $Path.Substring($root.Length).TrimStart('\')
    foreach ($include in $includeRelativePaths) {
        if ($relative.Equals($include, [System.StringComparison]::OrdinalIgnoreCase) -or
            $relative.StartsWith("$include\", [System.StringComparison]::OrdinalIgnoreCase)) {
            return 'include'
        }
    }

    if (Test-Path -LiteralPath (Join-Path $Path '.git')) {
        return 'git-remote'
    }

    return 'review'
}

$rows = foreach ($item in Get-ChildItem -LiteralPath $root -Force | Sort-Object FullName) {
    if ($item.Name -eq '.git') {
        continue
    }

    [pscustomobject]@{
        path = $item.FullName
        name = $item.Name
        backupClass = Get-BackupClass -Path $item.FullName
    }
}

if ($Json) {
    $rows | ConvertTo-Json -Depth 5
} else {
    $rows | Format-Table name, backupClass, path -AutoSize
}

# Write .sr for serializer daemon
if ($dxConfig) {
    Write-DxSr -Path (Join-Path $dxConfig.SrDir "test-backup-exclusions.sr") -Entries @{
        tool = "test-backup-exclusions"
        action = "run"
        status = "ok"
    }
}
