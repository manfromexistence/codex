param(
    [int]$WarningLines = 1000,
    [int]$MaximumLines = 2000,
    [int]$MaxFilesPerRepo = 120,
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
$baselinePath = Join-Path $root 'docs\policies\maintainability-baseline.json'
$sourceExtensions = @('.rs', '.ts', '.tsx', '.js', '.jsx', '.py', '.go', '.ps1')
$ignoredParts = @(
    '\.git\',
    '\.cargo-home\',
    '\.cargo\registry\',
    '\.dx\',
    '\.worktrees\',
    '\target\',
    '\node_modules\',
    '\.next\',
    '\dist\',
    '\build\',
    '\.tmp\',
    '\trash\',
    '\vendor\'
)
$forbiddenNameParts = @('vibe', 'slop', 'tmp', 'final-final', 'test2', 'newnew')
$monitoredRelativePaths = @(
    'www\dx-www\src\cli\readiness.rs',
    'cli\src\host_verify.rs',
    'forge\src\main.rs',
    'forge\src\cli\vibe_demo.rs'
)

$findings = New-Object System.Collections.Generic.List[object]
$lineBaselines = @{}

if (Test-Path -LiteralPath $baselinePath) {
    $baseline = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
    foreach ($entry in @($baseline.entries)) {
        if ($entry.path -and $entry.baselineLines) {
            $lineBaselines[[string]$entry.path] = [int]$entry.baselineLines
        }
    }
}

$monitoredRelativePaths = @($monitoredRelativePaths + $lineBaselines.Keys) | Sort-Object -Unique

function Test-IgnoredPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    foreach ($part in $ignoredParts) {
        if ($Path.IndexOf($part, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    return $false
}

function Get-SourceLineCount {
    param([Parameter(Mandatory = $true)][string]$Path)

    $lineCount = 0
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        $lineCount++
    }

    return $lineCount
}

foreach ($repo in Get-ChildItem -LiteralPath $root -Force -Directory | Sort-Object Name) {
    if ($repo.Name -in @('.dx', 'trash', 'tools')) {
        continue
    }

    if (-not (Test-Path -LiteralPath (Join-Path $repo.FullName '.git'))) {
        continue
    }

    $isRepo = & git -C $repo.FullName rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or $isRepo -ne 'true') {
        continue
    }

    $filesByPath = [ordered]@{}
    $discoveredFiles = Get-ChildItem -LiteralPath $repo.FullName -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            ($sourceExtensions -contains $_.Extension) -and
            -not (Test-IgnoredPath -Path $_.FullName)
        } |
        Sort-Object FullName |
        Select-Object -First $MaxFilesPerRepo

    foreach ($file in $discoveredFiles) {
        $filesByPath[$file.FullName] = $file
    }

    foreach ($relativePath in $monitoredRelativePaths) {
        if (-not $relativePath.StartsWith("$($repo.Name)\", [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $fullPath = Join-Path $root $relativePath
        if (-not (Test-Path -LiteralPath $fullPath)) {
            continue
        }

        $file = Get-Item -LiteralPath $fullPath
        if (($sourceExtensions -contains $file.Extension) -and -not (Test-IgnoredPath -Path $file.FullName)) {
            $filesByPath[$file.FullName] = $file
        }
    }

    foreach ($file in $filesByPath.Values) {
        $relative = $file.FullName.Substring($root.Length + 1)
        foreach ($part in $forbiddenNameParts) {
            if ($relative.ToLowerInvariant().Contains($part)) {
                $findings.Add([pscustomobject]@{
                    severity = 'warning'
                    repo = $repo.Name
                    path = $relative
                    rule = 'professional-name'
                    detail = "Name contains '$part'"
                })
            }
        }

        $lineCount = Get-SourceLineCount -Path $file.FullName

        if ($lineCount -gt $MaximumLines) {
            if ($lineBaselines.ContainsKey($relative)) {
                $baselineLines = $lineBaselines[$relative]
                if ($lineCount -gt $baselineLines) {
                    $findings.Add([pscustomobject]@{
                        severity = 'error'
                        repo = $repo.Name
                        path = $relative
                        rule = 'baseline-growth'
                        detail = "$lineCount lines exceeds baseline $baselineLines"
                    })
                } else {
                    $findings.Add([pscustomobject]@{
                        severity = 'warning'
                        repo = $repo.Name
                        path = $relative
                        rule = 'tracked-large-file'
                        detail = "$lineCount lines; split plan required before growth"
                    })
                }
            } else {
                $findings.Add([pscustomobject]@{
                    severity = 'error'
                    repo = $repo.Name
                    path = $relative
                    rule = 'file-too-large'
                    detail = "$lineCount lines exceeds $MaximumLines"
                })
            }
        } elseif ($lineCount -gt $WarningLines) {
            $findings.Add([pscustomobject]@{
                severity = 'warning'
                repo = $repo.Name
                path = $relative
                rule = 'large-file'
                detail = "$lineCount lines exceeds $WarningLines"
            })
        }
    }
}

$result = [pscustomobject]@{
    generatedAt = (Get-Date).ToString('s')
    warningLines = $WarningLines
    maximumLines = $MaximumLines
    baselinePath = $baselinePath
    findingCount = $findings.Count
    errors = @($findings | Where-Object { $_.severity -eq 'error' }).Count
    warnings = @($findings | Where-Object { $_.severity -eq 'warning' }).Count
    findings = $findings
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
} else {
    $findings | Format-Table severity, repo, rule, path, detail -AutoSize -Wrap
    ''
    "Findings: $($result.findingCount)"
    "Errors: $($result.errors)"
    "Warnings: $($result.warnings)"
}

if ($result.errors -gt 0) {
    exit 1
}

# Write .sr for serializer daemon
if ($dxConfig) {
    Write-DxSr -Path (Join-Path $dxConfig.SrDir "check-maintainability.sr") -Entries @{
        tool = "check-maintainability"
        action = "run"
        status = "ok"
    }
}
