param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('serializer', 'check', 'cli', 'style', 'forge')]
    [string]$Project,

    [string]$OutputPath,
    [string]$GitHubOwner = 'millercarla211-ctrl',
    [string]$DefaultBranch = 'dev',
    [string]$RustVersion = '1.94.0',
    [switch]$Print
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

function Get-ProjectProfiles {
    @{
        serializer = [ordered]@{
            ProjectName = 'dx-serializer'
            Repository = 'dx-serializer'
            Package = 'dx-serializer'
            Binaries = @('dx-serializer')
            Dependencies = @()
        }
        check = [ordered]@{
            ProjectName = 'dx-check'
            Repository = 'dx-check'
            Package = 'dx-check-engine'
            Binaries = @('dx-check-web-audit')
            Dependencies = @('serializer')
        }
        cli = [ordered]@{
            ProjectName = 'dx-cli'
            Repository = 'dx-cli'
            Package = 'dx-cli'
            Binaries = @('dx')
            Dependencies = @('check', 'serializer')
        }
        style = [ordered]@{
            ProjectName = 'dx-style'
            Repository = 'dx-style'
            Package = 'dx-style'
            Binaries = @('dx-style', 'analyze_styles')
            Dependencies = @('serializer')
        }
        forge = [ordered]@{
            ProjectName = 'forge'
            Repository = 'forge'
            Package = 'forge'
            Binaries = @('forge')
            Dependencies = @('serializer')
        }
    }
}

function Get-DependencyRepositories {
    @{
        check = 'dx-check'
        serializer = 'dx-serializer'
    }
}

function New-BashDependencyCommand {
    param(
        [AllowEmptyCollection()][string[]]$Dependencies = @(),
        [Parameter(Mandatory = $true)][hashtable]$Repositories,
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$FallbackBranch
    )

    $Dependencies = @($Dependencies | ForEach-Object { [string]$_ })
    $Owner = [string]$Owner
    $FallbackBranch = [string]$FallbackBranch

    $fallbackBranchLine = "fallback_branch=`"$FallbackBranch`""
    $defaultOwnerLine = "default_owner=`"$Owner`""

    $lines = @(
        'set -euo pipefail',
        $fallbackBranchLine,
        $defaultOwnerLine,
        '',
        'clone_dx_dependency() {',
        '  name="$1"',
        '  repository="$2"',
        '  target="../${name}"',
        '  if [ -d "${target}/.git" ]; then',
        '    echo "Dependency ${name} already exists at ${target}"',
        '    return 0',
        '  fi',
        '  branch="${CIRCLE_BRANCH:-$fallback_branch}"',
        '  owner="${DX_GITHUB_OWNER:-$default_owner}"',
        '  url="https://github.com/${owner}/${repository}.git"',
        '  clone_dependency() {',
        '    selected_branch="$1"',
        '    if [ -n "${DX_GITHUB_TOKEN:-}" ]; then',
        '      echo "Using configured GitHub token for private dependency ${owner}/${repository}."',
        '      export DX_GITHUB_TOKEN',
        '      askpass="$(mktemp)"',
        '      cat > "${askpass}" \<<''EOF''',
        '#!/usr/bin/env sh',
        'case "$1" in',
        '  *Username*) printf "%s\n" "x-access-token" ;;',
        '  *Password*) printf "%s\n" "${DX_GITHUB_TOKEN}" ;;',
        '  *) printf "\n" ;;',
        'esac',
        'EOF',
        '      chmod 700 "${askpass}"',
        '      auth_url="https://x-access-token@github.com/${owner}/${repository}.git"',
        '      GIT_ASKPASS="${askpass}" GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "${selected_branch}" "${auth_url}" "${target}"',
        '      status="$?"',
        '      rm -f "${askpass}"',
        '      return "${status}"',
        '    else',
        '      echo "DX_GITHUB_TOKEN is not configured; trying unauthenticated dependency clone."',
        '      git clone --depth 1 --branch "${selected_branch}" "${url}" "${target}"',
        '    fi',
        '  }',
        '  clone_dependency "${branch}" || clone_dependency "${fallback_branch}" || {',
        '    echo "Failed to clone dependency ${name} from ${owner}/${repository}. Private sibling dependencies require a scoped read token or an SSH key strategy." >&2',
        '    return 1',
        '  }',
        '}',
        ''
    )

    if ($Dependencies.Count -eq 0) {
        $lines += 'echo "No sibling Cargo dependencies are required."'
    } else {
        foreach ($dependency in $Dependencies) {
            $lines += "clone_dx_dependency `"$dependency`" `"$($Repositories[$dependency])`""
        }
    }

    $lines -join "`n"
}

function New-PowerShellDependencyCommand {
    param(
        [AllowEmptyCollection()][string[]]$Dependencies = @(),
        [Parameter(Mandatory = $true)][hashtable]$Repositories,
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$FallbackBranch
    )

    $Dependencies = @($Dependencies | ForEach-Object { [string]$_ })
    $Owner = [string]$Owner
    $FallbackBranch = [string]$FallbackBranch

    $fallbackBranchLine = "`$fallbackBranch = `"$FallbackBranch`""
    $defaultOwnerLine = "`$defaultOwner = `"$Owner`""

    $lines = @(
        '$ErrorActionPreference = "Stop"',
        $fallbackBranchLine,
        $defaultOwnerLine,
        'function Clone-DxDependency {',
        '    param([string]$Name, [string]$Repository)',
        '    $target = Join-Path ".." $Name',
        '    if (Test-Path -LiteralPath (Join-Path $target ".git")) {',
        '        Write-Host "Dependency $Name already exists at $target"',
        '        return',
        '    }',
        '    $branch = if ($env:CIRCLE_BRANCH) { $env:CIRCLE_BRANCH } else { $fallbackBranch }',
        '    $owner = if ($env:DX_GITHUB_OWNER) { $env:DX_GITHUB_OWNER } else { $defaultOwner }',
        '    $url = "https://github.com/$owner/$Repository.git"',
        '    $gitArgs = @()',
        '    if ($env:DX_GITHUB_TOKEN) {',
        '        $authHeader = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$env:DX_GITHUB_TOKEN"))',
        '        $gitArgs += @("-c", "http.https://github.com/.extraheader=AUTHORIZATION: basic $authHeader")',
        '    }',
        '    git @gitArgs clone --depth 1 --branch $branch $url $target',
        '    if ($LASTEXITCODE -ne 0) {',
        '        git @gitArgs clone --depth 1 --branch $fallbackBranch $url $target',
        '    }',
        '    if ($LASTEXITCODE -ne 0) {',
        '        throw "Failed to clone dependency $Name from $owner/$Repository. Private sibling dependencies require a scoped read token or an SSH key strategy."',
        '    }',
        '}',
        ''
    )

    if ($Dependencies.Count -eq 0) {
        $lines += 'Write-Host "No sibling Cargo dependencies are required."'
    } else {
        foreach ($dependency in $Dependencies) {
            $lines += "Clone-DxDependency -Name `"$dependency`" -Repository `"$($Repositories[$dependency])`""
        }
    }

    $lines -join "`n"
}

function Convert-ToIndentedBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$Spaces = 12
    )

    $prefix = ' ' * $Spaces
    [string]::Join("`n", (($Text -split "`n") | ForEach-Object { "$prefix$_" }))
}

function New-BashReleaseCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectName,
        [Parameter(Mandatory = $true)][string[]]$Binaries,
        [Parameter(Mandatory = $true)][string]$Platform
    )

    $ProjectName = [string]$ProjectName
    $Binaries = @($Binaries | ForEach-Object { [string]$_ })
    $Platform = [string]$Platform
    $binaryArguments = ($Binaries | ForEach-Object { "--bin $_" }) -join ' '
    $binaryList = $Binaries -join ' '
    $archivePrefix = "$ProjectName-$Platform"
    $copyLines = foreach ($binary in $Binaries) {
        "cp `"target/release/$binary`" `"dist/$binary`""
    }

    @(
        'set -euo pipefail',
        "cargo build --locked --release $binaryArguments",
        'mkdir -p dist',
        $copyLines,
        'short_sha="$(printf "%.12s" "${CIRCLE_SHA1}")"',
        "archive=`"$archivePrefix-`${short_sha}.tar.gz`"",
        "tar -czf `"dist/`${archive}`" -C dist $binaryList",
        '(cd dist && shasum -a 256 "${archive}" > SHA256SUMS.txt)'
    ) -join "`n"
}

function New-WindowsReleaseCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectName,
        [Parameter(Mandatory = $true)][string[]]$Binaries
    )

    $ProjectName = [string]$ProjectName
    $Binaries = @($Binaries | ForEach-Object { [string]$_ })
    $binaryArguments = ($Binaries | ForEach-Object { "--bin $_" }) -join ' '
    $archivePrefix = "$ProjectName-windows-x86_64"
    $copyLines = foreach ($binary in $Binaries) {
        "Copy-Item -LiteralPath `"target\release\$binary.exe`" -Destination `"dist\$binary.exe`""
    }

    @(
        '$ErrorActionPreference = "Stop"',
        "cargo build --locked --release $binaryArguments",
        'New-Item -ItemType Directory -Path dist -Force | Out-Null',
        $copyLines,
        '$shortSha = $env:CIRCLE_SHA1.Substring(0, 12)',
        "`$archive = `"$archivePrefix-`$shortSha.zip`"",
        'Compress-Archive -Path "dist\*.exe" -DestinationPath "dist\$archive" -Force',
        '$hash = Get-FileHash -Algorithm SHA256 -LiteralPath "dist\$archive"',
        '"$($hash.Hash.ToLowerInvariant())  $archive" | Set-Content -LiteralPath "dist\SHA256SUMS.txt" -Encoding ASCII'
    ) -join "`n"
}

function New-CircleCiConfig {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Profile,
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$FallbackBranch,
        [Parameter(Mandatory = $true)][string]$RustVersion
    )

    $projectName = [string]$Profile['ProjectName']
    $binaries = @($Profile['Binaries'] | ForEach-Object { [string]$_ })
    $dependencies = @($Profile['Dependencies'] | ForEach-Object { [string]$_ })
    $Owner = [string]$Owner
    $FallbackBranch = [string]$FallbackBranch
    $RustVersion = [string]$RustVersion

    $repositories = Get-DependencyRepositories
    $bashDependencies = Convert-ToIndentedBlock -Text (New-BashDependencyCommand -Dependencies $dependencies -Repositories $repositories -Owner $Owner -FallbackBranch $FallbackBranch)
    $windowsDependencies = Convert-ToIndentedBlock -Text (New-PowerShellDependencyCommand -Dependencies $dependencies -Repositories $repositories -Owner $Owner -FallbackBranch $FallbackBranch)
    $linuxRelease = Convert-ToIndentedBlock -Text (New-BashReleaseCommand -ProjectName $projectName -Binaries $binaries -Platform 'linux-x86_64')
    $macRelease = Convert-ToIndentedBlock -Text (New-BashReleaseCommand -ProjectName $projectName -Binaries $binaries -Platform 'macos-arm64')
    $windowsRelease = Convert-ToIndentedBlock -Text (New-WindowsReleaseCommand -ProjectName $projectName -Binaries $binaries)

@"
version: 2.1

orbs:
  win: circleci/windows@5.0

parameters:
  linux_release_artifacts:
    type: boolean
    default: false
  release_artifacts:
    type: boolean
    default: false

commands:
  prepare_unix_workspace:
    steps:
      - run:
          name: Checkout sibling Cargo dependencies
          command: |
$bashDependencies
  prepare_windows_workspace:
    steps:
      - run:
          name: Checkout sibling Cargo dependencies
          shell: powershell.exe
          command: |
$windowsDependencies

jobs:
  linux-check:
    docker:
      - image: cimg/rust:$RustVersion
    resource_class: small
    steps:
      - checkout
      - prepare_unix_workspace
      - restore_cache:
          keys:
            - cargo-{{ arch }}-{{ checksum "Cargo.lock" }}
            - cargo-{{ arch }}-
      - run:
          name: Cargo metadata
          command: cargo metadata --locked --no-deps --format-version 1
      - run:
          name: Cargo check
          command: cargo check --locked --lib --bins --tests --examples
      - save_cache:
          key: cargo-{{ arch }}-{{ checksum "Cargo.lock" }}
          paths:
            - ~/.cargo/registry
            - ~/.cargo/git
            - target

  linux-release:
    docker:
      - image: cimg/rust:$RustVersion
    resource_class: medium
    steps:
      - checkout
      - prepare_unix_workspace
      - run:
          name: Build Linux release artifacts
          command: |
$linuxRelease
      - store_artifacts:
          path: dist

  windows-release:
    executor:
      name: win/default
      size: medium
    steps:
      - checkout
      - run:
          name: Install Rust
          shell: powershell.exe
          command: |
            Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" -OutFile "rustup-init.exe"
            .\rustup-init.exe -y --default-toolchain $RustVersion --profile minimal
      - prepare_windows_workspace
      - run:
          name: Build Windows release artifacts
          shell: powershell.exe
          command: |
            `$env:Path = "`$env:USERPROFILE\.cargo\bin;`$env:Path"
$windowsRelease
      - store_artifacts:
          path: dist

  macos-release:
    macos:
      xcode: 26.4.1
    resource_class: m4pro.medium
    steps:
      - checkout
      - run:
          name: Install Rust
          command: curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain $RustVersion --profile minimal
      - prepare_unix_workspace
      - run:
          name: Build macOS release artifacts
          command: |
            . "`$HOME/.cargo/env"
$macRelease
      - store_artifacts:
          path: dist

workflows:
  validate:
    jobs:
      - linux-check:
          filters:
            branches:
              only:
                - main
                - dev

  release:
    when: << pipeline.parameters.release_artifacts >>
    jobs:
      - linux-release
      - windows-release
      - macos-release

  linux-release-smoke:
    when: << pipeline.parameters.linux_release_artifacts >>
    jobs:
      - linux-release
"@
}

$profiles = Get-ProjectProfiles
$profile = $profiles[$Project]
$config = New-CircleCiConfig -Profile $profile -Owner $GitHubOwner -FallbackBranch $DefaultBranch -RustVersion $RustVersion

if (-not $OutputPath) {
    $OutputPath = Join-Path (Join-Path (Get-Location).Path '.circleci') 'config.yml'
}

if ($Print) {
    $config
    return
}

$parent = Split-Path -Parent $OutputPath
if ($parent) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

Set-Content -LiteralPath $OutputPath -Value $config -Encoding UTF8
Write-Host "Wrote CircleCI config for $Project to $OutputPath"

# Write .sr for serializer daemon
if ($dxConfig) {
    Write-DxSr -Path (Join-Path $dxConfig.SrDir "write-circleci-rust-release-config.sr") -Entries @{
        tool = "write-circleci-rust-release-config"
        action = "run"
        status = "ok"
    }
}
