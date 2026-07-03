param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [string]$GitHubOwner = 'millercarla211-ctrl',
    [string]$GitLabHost = 'gitlab.com',
    [string]$GitLabNamespace = $env:GITLAB_NAMESPACE,
    [string]$GitLabToken = $(if ($env:GITLAB_TOKEN) { $env:GITLAB_TOKEN } else { $env:GLAB_TOKEN }),
    [string[]]$Branches = @('main', 'dev'),
    [switch]$PushTags,
    [switch]$PushLfs,
    [switch]$AllowDirty,
    [switch]$UpdateRemote,
    [string]$OutputPath,
    [switch]$DryRun
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

        $originResult = Invoke-Git -Repository $path -Arguments @('remote', 'get-url', 'origin') -AllowFailure
        if ($originResult.ExitCode -ne 0 -or -not $originResult.Output) {
            continue
        }

        $origin = [string]$originResult.Output[0]
        $repoName = Get-GitHubRepositoryName -RemoteUrl $origin
        if (-not $repoName) {
            continue
        }

        $dirty = (Invoke-Git -Repository $path -Arguments @('status', '--porcelain')).Output.Count -gt 0
        $branch = (Invoke-Git -Repository $path -Arguments @('branch', '--show-current')).Output[0]
        $localBranches = (Invoke-Git -Repository $path -Arguments @('branch', '--format=%(refname:short)')).Output

        [pscustomobject]@{
            Name = if ($path -eq $Root) { 'root' } else { Split-Path -Leaf $path }
            Path = $path
            RepositoryName = $repoName
            GitHubUrl = $origin
            CurrentBranch = $branch
            LocalBranches = @($localBranches)
            Dirty = $dirty
        }
    }
}

function New-MirrorReport {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)]$Rows,
        [string]$Namespace
    )

    [pscustomobject]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        mode = $Mode
        root = (Resolve-Path -LiteralPath $Root).Path
        gitHubOwner = $GitHubOwner
        gitLabHost = $GitLabHost
        gitLabNamespace = $Namespace
        branches = @($Branches)
        pushTags = [bool]$PushTags
        pushLfs = [bool]$PushLfs
        allowDirty = [bool]$AllowDirty
        repositories = @($Rows)
    }
}

function Write-MirrorReport {
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

function New-GitLabHeaders {
    if (-not $GitLabToken) {
        throw 'Set GITLAB_TOKEN or GLAB_TOKEN before running without -DryRun.'
    }

    @{
        'PRIVATE-TOKEN' = $GitLabToken
    }
}

function Invoke-GitLabApi {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Body
    )

    $uri = "https://$GitLabHost/api/v4/$Path"
    $headers = New-GitLabHeaders
    if ($Body) {
        $payload = $Body | ConvertTo-Json -Depth 8
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType 'application/json' -Body $payload
    }

    Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

function Get-GitLabNamespace {
    if ($GitLabNamespace) {
        $encodedSearch = [uri]::EscapeDataString($GitLabNamespace)
        $matches = Invoke-GitLabApi -Method 'GET' -Path "namespaces?search=$encodedSearch"
        $exact = @($matches | Where-Object { $_.full_path -eq $GitLabNamespace -or $_.path -eq $GitLabNamespace }) |
            Select-Object -First 1
        if (-not $exact) {
            throw "GitLab namespace not found or not accessible: $GitLabNamespace"
        }

        return $exact
    }

    $user = Invoke-GitLabApi -Method 'GET' -Path 'user'
    return [pscustomobject]@{
        id = $user.id
        path = $user.username
        full_path = $user.username
    }
}

function Get-GitLabProject {
    param(
        [Parameter(Mandatory = $true)][string]$Namespace,
        [Parameter(Mandatory = $true)][string]$RepositoryName
    )

    $fullPath = [uri]::EscapeDataString("$Namespace/$RepositoryName")
    try {
        return Invoke-GitLabApi -Method 'GET' -Path "projects/$fullPath"
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            return $null
        }

        throw
    }
}

function Ensure-GitLabProject {
    param(
        [Parameter(Mandatory = $true)]$Namespace,
        [Parameter(Mandatory = $true)][string]$RepositoryName
    )

    $namespacePath = $Namespace.full_path
    $existing = Get-GitLabProject -Namespace $namespacePath -RepositoryName $RepositoryName
    if ($existing) {
        return [pscustomobject]@{ Project = $existing; Created = $false }
    }

    $body = @{
        name = $RepositoryName
        path = $RepositoryName
        namespace_id = $Namespace.id
        visibility = 'private'
        initialize_with_readme = 'false'
    }
    $project = Invoke-GitLabApi -Method 'POST' -Path 'projects' -Body $body
    [pscustomobject]@{ Project = $project; Created = $true }
}

function Ensure-GitLabRemote {
    param(
        [Parameter(Mandatory = $true)]$Repository,
        [Parameter(Mandatory = $true)][string]$RemoteUrl
    )

    $remoteResult = Invoke-Git -Repository $Repository.Path -Arguments @('remote', 'get-url', 'gitlab') -AllowFailure
    if ($remoteResult.ExitCode -eq 0) {
        $current = [string]$remoteResult.Output[0]
        if ($current -eq $RemoteUrl) {
            return 'unchanged'
        }

        if (-not $UpdateRemote) {
            throw "$($Repository.Name) already has gitlab remote '$current'. Use -UpdateRemote to replace it with '$RemoteUrl'."
        }

        Invoke-Git -Repository $Repository.Path -Arguments @('remote', 'set-url', 'gitlab', $RemoteUrl) | Out-Null
        return 'updated'
    }

    Invoke-Git -Repository $Repository.Path -Arguments @('remote', 'add', 'gitlab', $RemoteUrl) | Out-Null
    'added'
}

function New-AskPassFiles {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) "dx-gitlab-askpass-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $ps1 = Join-Path $dir 'askpass.ps1'
    $cmd = Join-Path $dir 'askpass.cmd'

    Set-Content -LiteralPath $ps1 -Encoding ASCII -Value @'
$prompt = $args -join ' '
if ($prompt -match 'Username') {
    'oauth2'
} else {
    $env:DX_GITLAB_TOKEN
}
'@

    Set-Content -LiteralPath $cmd -Encoding ASCII -Value @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "$ps1" %*
"@

    [pscustomobject]@{
        Directory = $dir
        Command = $cmd
    }
}

function Invoke-WithGitLabAskPass {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)

    $askPass = New-AskPassFiles
    $previousAskPass = $env:GIT_ASKPASS
    $previousPrompt = $env:GIT_TERMINAL_PROMPT
    $previousToken = $env:DX_GITLAB_TOKEN

    try {
        $env:GIT_ASKPASS = $askPass.Command
        $env:GIT_TERMINAL_PROMPT = '0'
        $env:DX_GITLAB_TOKEN = $GitLabToken
        & $Script
    } finally {
        $env:GIT_ASKPASS = $previousAskPass
        $env:GIT_TERMINAL_PROMPT = $previousPrompt
        $env:DX_GITLAB_TOKEN = $previousToken
        Remove-Item -LiteralPath $askPass.Directory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Push-Repository {
    param(
        [Parameter(Mandatory = $true)]$Repository,
        [Parameter(Mandatory = $true)][string[]]$BranchNames
    )

    Invoke-WithGitLabAskPass {
        foreach ($branchName in $BranchNames) {
            if ($Repository.LocalBranches -notcontains $branchName) {
                continue
            }

            Invoke-Git -Repository $Repository.Path -Arguments @('push', 'gitlab', "$branchName`:$branchName") | Out-Null
        }

        if ($PushTags) {
            Invoke-Git -Repository $Repository.Path -Arguments @('push', 'gitlab', '--tags') | Out-Null
        }

        if ($PushLfs) {
            $lfsVersion = Invoke-Git -Repository $Repository.Path -Arguments @('lfs', 'version') -AllowFailure
            if ($lfsVersion.ExitCode -eq 0) {
                $tracked = Invoke-Git -Repository $Repository.Path -Arguments @('lfs', 'ls-files') -AllowFailure
                if ($tracked.ExitCode -eq 0 -and $tracked.Output.Count -gt 0) {
                    Invoke-Git -Repository $Repository.Path -Arguments @('lfs', 'push', 'gitlab', '--all') | Out-Null
                }
            }
        }
    }
}

function Set-GitLabDefaultBranch {
    param(
        [Parameter(Mandatory = $true)]$Project,
        [Parameter(Mandatory = $true)]$Repository
    )

    if ($Repository.LocalBranches -notcontains 'main') {
        return
    }

    Invoke-GitLabApi -Method 'PUT' -Path "projects/$($Project.id)" -Body @{ default_branch = 'main' } | Out-Null
}

$repositories = @(Get-DxGitRepositories)
if ($repositories.Count -eq 0) {
    throw "No GitHub-backed repositories found under $Root for owner $GitHubOwner."
}

if ($DryRun) {
    $rows = @($repositories | ForEach-Object {
        [pscustomobject]@{
            name = $_.Name
            path = $_.Path
            repositoryName = $_.RepositoryName
            gitHubUrl = $_.GitHubUrl
            currentBranch = $_.CurrentBranch
            dirty = $_.Dirty
            branchesToPush = @($_.LocalBranches | Where-Object { $Branches -contains $_ })
            action = if ($_.Dirty -and -not $AllowDirty) { 'would-skip-dirty' } else { 'would-create-or-update-mirror' }
        }
    })
    $report = New-MirrorReport -Mode 'dry-run' -Rows $rows -Namespace $GitLabNamespace
    Write-MirrorReport -Report $report
    $rows |
        Select-Object name, path, repositoryName, currentBranch, dirty, @{ Name = 'branchesToPush'; Expression = { $_.branchesToPush -join ',' } }, action |
        Format-Table -AutoSize
    return
}

$namespace = Get-GitLabNamespace
$summary = foreach ($repo in $repositories) {
    if ($repo.Dirty -and -not $AllowDirty) {
        [pscustomobject]@{
            repository = $repo.Name
            path = $repo.Path
            repositoryName = $repo.RepositoryName
            gitHubUrl = $repo.GitHubUrl
            gitLabProject = "$($namespace.full_path)/$($repo.RepositoryName)"
            status = 'skipped-dirty'
            remote = ''
            branchesPushed = @()
        }
        continue
    }

    $projectState = Ensure-GitLabProject -Namespace $namespace -RepositoryName $repo.RepositoryName
    $remoteUrl = "https://$GitLabHost/$($namespace.full_path)/$($repo.RepositoryName).git"
    $remoteState = Ensure-GitLabRemote -Repository $repo -RemoteUrl $remoteUrl
    $branchesToPush = @($repo.LocalBranches | Where-Object { $Branches -contains $_ })
    Push-Repository -Repository $repo -BranchNames $branchesToPush
    Set-GitLabDefaultBranch -Project $projectState.Project -Repository $repo

    [pscustomobject]@{
        repository = $repo.Name
        path = $repo.Path
        repositoryName = $repo.RepositoryName
        gitHubUrl = $repo.GitHubUrl
        gitLabProject = "$($namespace.full_path)/$($repo.RepositoryName)"
        status = if ($projectState.Created) { 'created' } else { 'existing' }
        remote = $remoteState
        branchesPushed = @($branchesToPush)
    }
}

$report = New-MirrorReport -Mode 'sync' -Rows $summary -Namespace $namespace.full_path
Write-MirrorReport -Report $report
$summary |
    Select-Object repository, gitLabProject, status, remote, @{ Name = 'branchesPushed'; Expression = { $_.branchesPushed -join ',' } } |
    Format-Table -AutoSize

# Write .sr for serializer daemon
if ($dxConfig) {
    Write-DxSr -Path (Join-Path $dxConfig.SrDir "sync-gitlab-mirrors.sr") -Entries @{
        tool = "sync-gitlab-mirrors"
        action = "run"
        status = "ok"
    }
}
