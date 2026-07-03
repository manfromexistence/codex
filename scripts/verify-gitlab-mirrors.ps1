param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$GitHubOwner = 'millercarla211-ctrl',
    [string]$RemoteName = 'gitlab',
    [string[]]$Branches = @('main', 'dev'),
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

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & git -C $Repository @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "git -C $Repository $($Arguments -join ' ') failed with exit code ${code}: $($output -join "`n")"
    }

    [pscustomobject]@{
        ExitCode = $code
        Output = @($output)
    }
}

function Get-GitHubRepositoryName {
    param([Parameter(Mandatory = $true)][string]$RemoteUrl)

    $escapedOwner = [regex]::Escape($GitHubOwner)
    if ($RemoteUrl -match "github\.com[:/]$escapedOwner/([^/]+?)(\.git)?$") {
        return $Matches[1]
    }

    return $null
}

function Get-DxGitRepositories {
    $paths = @($Root)
    $paths += Get-ChildItem -LiteralPath $Root -Force -Directory |
        Where-Object { $_.Name -notin @('.git', '.dx', '.github', 'docs', 'scripts', 'trash') } |
        Sort-Object Name |
        ForEach-Object { $_.FullName }

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) {
            continue
        }

        $origin = Invoke-Git -Repository $path -Arguments @('remote', 'get-url', 'origin') -AllowFailure
        if ($origin.ExitCode -ne 0 -or -not $origin.Output) {
            continue
        }

        $repoName = Get-GitHubRepositoryName -RemoteUrl ([string]$origin.Output[0])
        if (-not $repoName) {
            continue
        }

        [pscustomobject]@{
            Name = if ($path -eq $Root) { 'root' } else { Split-Path -Leaf $path }
            Path = $path
            RepositoryName = $repoName
            GitHubUrl = [string]$origin.Output[0]
        }
    }
}

function Test-TokenInRemoteUrl {
    param([string]$Url)

    if (-not $Url) {
        return $false
    }

    $Url -match '^https?://[^/]*@'
}

function Get-LfsTrackedCount {
    param([Parameter(Mandatory = $true)][string]$Repository)

    $version = Invoke-Git -Repository $Repository -Arguments @('lfs', 'version') -AllowFailure
    if ($version.ExitCode -ne 0) {
        return 0
    }

    $tracked = Invoke-Git -Repository $Repository -Arguments @('lfs', 'ls-files') -AllowFailure
    if ($tracked.ExitCode -ne 0) {
        return 0
    }

    @($tracked.Output).Count
}

function Get-RemoteBranchNames {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Remote
    )

    $result = Invoke-Git -Repository $Repository -Arguments @('ls-remote', '--heads', $Remote) -AllowFailure
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{
            Reachable = $false
            Branches = @()
            Error = ($result.Output -join "`n")
        }
    }

    $names = @($result.Output | ForEach-Object {
        if ($_ -match 'refs/heads/(.+)$') {
            $Matches[1]
        }
    })

    [pscustomobject]@{
        Reachable = $true
        Branches = $names
        Error = ''
    }
}

function Write-VerificationReport {
    param([Parameter(Mandatory = $true)]$Report)

    if (-not $OutputPath) {
        return
    }

    $parent = Split-Path -Parent $OutputPath
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}

$rows = foreach ($repo in Get-DxGitRepositories) {
    $remoteResult = Invoke-Git -Repository $repo.Path -Arguments @('remote', 'get-url', $RemoteName) -AllowFailure
    $remoteUrl = if ($remoteResult.ExitCode -eq 0 -and $remoteResult.Output) { [string]$remoteResult.Output[0] } else { '' }
    $branchProbe = if ($remoteUrl) { Get-RemoteBranchNames -Repository $repo.Path -Remote $RemoteName } else { [pscustomobject]@{ Reachable = $false; Branches = @(); Error = '' } }
    $missingBranches = @($Branches | Where-Object { $branchProbe.Branches -notcontains $_ })
    $tokenInRemote = Test-TokenInRemoteUrl -Url $remoteUrl

    $status = if (-not $remoteUrl) {
        'missing-gitlab-remote'
    } elseif ($tokenInRemote) {
        'unsafe-token-in-remote'
    } elseif (-not $branchProbe.Reachable) {
        'remote-unreachable'
    } elseif ($missingBranches.Count -gt 0) {
        'missing-branches'
    } else {
        'ok'
    }

    [pscustomobject]@{
        name = $repo.Name
        path = $repo.Path
        repositoryName = $repo.RepositoryName
        gitHubUrl = $repo.GitHubUrl
        gitLabUrl = $remoteUrl
        tokenInGitLabRemote = $tokenInRemote
        remoteReachable = $branchProbe.Reachable
        expectedBranches = @($Branches)
        remoteBranches = @($branchProbe.Branches)
        missingBranches = $missingBranches
        lfsTrackedFiles = Get-LfsTrackedCount -Repository $repo.Path
        status = $status
    }
}

$report = [pscustomobject]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    root = (Resolve-Path -LiteralPath $Root).Path
    gitHubOwner = $GitHubOwner
    remoteName = $RemoteName
    branches = @($Branches)
    repositories = @($rows)
}

Write-VerificationReport -Report $report
$rows |
    Select-Object name, repositoryName, status, remoteReachable, @{ Name = 'missingBranches'; Expression = { $_.missingBranches -join ',' } }, lfsTrackedFiles |
    Format-Table -AutoSize

# Write .sr for serializer daemon
if ($dxConfig) {
    Write-DxSr -Path (Join-Path $dxConfig.SrDir "verify-gitlab-mirrors.sr") -Entries @{
        tool = "verify-gitlab-mirrors"
        action = "run"
        status = "ok"
    }
}
