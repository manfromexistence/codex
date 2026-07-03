param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string[]]$Projects = @('serializer', 'check', 'cli', 'style', 'forge'),
    [int]$MaxCpuLoadPercent = 85,
    [switch]$SkipCircleCi,
    [switch]$Force
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
Set-StrictMode -Version Latest

function Get-CpuLoadPercent {
    $load = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    if ($null -eq $load) {
        return 0
    }

    [int][math]::Round($load)
}

function Get-CircleCiCommand {
    $command = Get-Command circleci -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    return $null
}

$generator = Join-Path $Root 'scripts\write-circleci-rust-release-config.ps1'
if (-not (Test-Path -LiteralPath $generator)) {
    throw "Generator not found: $generator"
}

$cpuLoad = Get-CpuLoadPercent
if (-not $SkipCircleCi -and -not $Force -and $cpuLoad -gt $MaxCpuLoadPercent) {
    throw "CPU load is $cpuLoad%, above the $MaxCpuLoadPercent% safety threshold. Re-run with -SkipCircleCi for source-only validation or -Force when remote validation is worth it."
}

$circleci = if ($SkipCircleCi) { $null } else { Get-CircleCiCommand }
if (-not $SkipCircleCi -and -not $circleci) {
    throw 'CircleCI CLI was not found. Re-run with -SkipCircleCi for source-only validation.'
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dx-circleci-config-" + [System.Guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $results = foreach ($project in $Projects) {
        $output = Join-Path $tempRoot "$project\.circleci\config.yml"
        & powershell -NoProfile -ExecutionPolicy Bypass -File $generator -Project $project -OutputPath $output | Out-Null

        if (-not (Test-Path -LiteralPath $output)) {
            throw "Config was not generated for $project"
        }

        $status = 'generated'
        if ($circleci) {
            & $circleci config validate $output | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "CircleCI config validation failed for $project"
            }
            $status = 'validated'
        }

        [pscustomobject]@{
            project = $project
            status = $status
            path = $output
        }
    }

    $results | Format-Table -AutoSize
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

# Write .sr for serializer daemon
if ($dxConfig) {
    Write-DxSr -Path (Join-Path $dxConfig.SrDir "test-circleci-rust-release-config.sr") -Entries @{
        tool = "test-circleci-rust-release-config"
        action = "run"
        status = "ok"
    }
}
