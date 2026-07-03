# DX config discovery and loading for PowerShell tools.
#
# Usage:
#   Import-Module "$PSScriptRoot\dx-config.psm1"
#   $config = Get-DxConfig
#   $config.CliPath
#   $config.ResolvePath("cli")

function Get-DxConfig {
    <#
    .SYNOPSIS
        Discover and load the nearest extensionless `dx` config file.
    .DESCRIPTION
        Walks up from the current directory (or -Path) looking for a `dx` file.
        Skips project-level Serializer configs. Returns a DxConfig object.
    .PARAMETER Path
        Starting directory for discovery (default: current directory).
    #>
    param(
        [string]$Path = (Get-Location)
    )

    $dxHome = [Environment]::GetEnvironmentVariable("DX_HOME")
    if ($dxHome) {
        $dxFile = Join-Path $dxHome "dx"
        if (Test-Path $dxFile -PathType Leaf) {
            return Read-DxConfig -Path $dxFile
        }
        return New-DxConfig -Root $dxHome
    }

    $current = (Resolve-Path $Path).Path
    $dxFile = Find-DxConfig -Start $current
    if (-not $dxFile) {
        return New-DxConfig -Root $current
    }
    return Read-DxConfig -Path $dxFile
}

function Find-DxConfig {
    param([string]$Start)
    $dir = $Start
    while ($dir) {
        $candidate = Join-Path $dir "dx"
        if ((Test-Path $candidate -PathType Leaf) -and -not (Test-IsProjectDx -Path $candidate)) {
            return $candidate
        }
        $parent = Split-Path $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Test-IsProjectDx {
    param([string]$Path)
    try {
        $firstLine = (Get-Content -Path $Path -TotalCount 1 -Encoding UTF8).TrimStart("`u{feff}")
        if ([string]::IsNullOrWhiteSpace($firstLine)) { return $false }
        if ($firstLine -match '^\s*(project|contract|runtime|www)\(') { return $true }
        if ($firstLine -match '\[' -and $firstLine -match '\(') { return $true }
    } catch {
        return $false
    }
    return $false
}

function Read-DxConfig {
    param([string]$Path)
    $root = Split-Path $Path -Parent
    $config = New-DxConfig -Root $root
    Get-Content -Path $Path -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { return }
        if ($line -match '^([a-zA-Z_][\w.]*)\s*=\s*"([^"]*)"$') {
            $config.Settings[$matches[1]] = $matches[2]
        }
    }
    return $config
}

function New-DxConfig {
    param([string]$Root)
    $config = [PSCustomObject]@{
        Root = (Resolve-Path $Root).Path
        Settings = @{}
    }
    $config | Add-Member -MemberType ScriptMethod -Name "ResolvePath" -Value {
        param([string]$Key)
        $raw = $this.Settings["paths.$Key"]
        if (-not $raw) { return Join-Path $this.Root $Key }
        $p = $raw -replace '^~', $env:USERPROFILE
        if ([System.IO.Path]::IsPathRooted($p)) { return $p }
        return [System.IO.Path]::GetFullPath((Join-Path $this.Root $p))
    } -Force
    $config | Add-Member -MemberType ScriptMethod -Name "Get" -Value {
        param([string]$Key, [string]$Default = "")
        if ($this.Settings.ContainsKey($Key)) { return $this.Settings[$Key] }
        return $Default
    } -Force
    $config | Add-Member -MemberType ScriptProperty -Name "CacheDir" -Value {
        $this.ResolvePath("cache")
    } -Force
    $config | Add-Member -MemberType ScriptProperty -Name "SrDir" -Value {
        Join-Path (Split-Path $this.ResolvePath("cache") -Parent) "serializer"
    } -Force
    $config | Add-Member -MemberType ScriptProperty -Name "CliPath" -Value {
        $this.ResolvePath("cli")
    } -Force
    return $config
}

function Write-DxSr {
    <#
    .SYNOPSIS
        Write a .sr file in DX LLM format (key=value pairs).
    .DESCRIPTION
        The serializer daemon (dx-sr-watch) auto-compiles .sr -> .machine.
        Call this to persist tool state for fast runtime loading.
    .PARAMETER Path
        Output .sr file path (e.g., ".dx/serializer/forge-cache.sr").
    .PARAMETER Entries
        Hashtable of flat key-value pairs to write.
    .EXAMPLE
        Write-DxSr -Path ".dx/serializer/forge-cache.sr" -Entries @{name="forge"; version="1.0.0"; status="ready"}
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [hashtable]$Entries
    )

    $parent = Split-Path $Path -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $Entries.Keys) {
        $value = $Entries[$key]
        $needsQuoting = [string]::IsNullOrEmpty($value) -or
            ($value -match '[\s"\[\]=#]')
        if ($needsQuoting) {
            $escaped = $value -replace '\\', '\\' -replace '"', '\"'
            $lines.Add("$key=`"$escaped`"")
        } else {
            $lines.Add("$key=$value")
        }
    }

    $content = ($lines -join "`n") + "`n"
    $tmp = [System.IO.Path]::ChangeExtension($Path, ".sr.tmp")
    [System.IO.File]::WriteAllText($tmp, $content, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Delete($Path -ne $tmp) 2>$null
    [System.IO.File]::Move($tmp, $Path)
}

Export-ModuleMember -Function Get-DxConfig, Write-DxSr
