param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('agent', 'build', 'dcp', 'driven', 'extensions', 'flow', 'i18n', 'icon', 'js', 'media', 'metasearch', 'native', 'providers')]
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
        agent = [ordered]@{
            DisplayName = 'dx-agents'
            CheckCommand = 'cargo check --locked -p dx-agents --lib --bin dx-agents'
            Dependencies = @()
        }
        build = [ordered]@{
            DisplayName = 'dx-build'
            CheckCommand = 'cargo check --locked -p rolldown --lib'
            Dependencies = @('serializer')
        }
        extensions = [ordered]@{
            DisplayName = 'dx-extensions'
            CheckCommand = 'cargo check --locked --workspace --lib --bins'
            Dependencies = @()
        }
        dcp = [ordered]@{
            DisplayName = 'dcp'
            CheckCommand = 'cargo check --locked --lib --bins'
            Dependencies = @()
        }
        driven = [ordered]@{
            DisplayName = 'dx-driven'
            CheckCommand = 'cargo check --locked --lib --bin driven'
            Dependencies = @('serializer', 'dcp', 'www')
        }
        flow = [ordered]@{
            DisplayName = 'flow'
            CheckCommand = 'cargo check --locked --lib --bin flow'
            Dependencies = @()
            SystemPackages = @(
                'libasound2-dev',
                'libx11-dev',
                'libxi-dev',
                'libxtst-dev',
                'libxrandr-dev',
                'libxinerama-dev',
                'libxcursor-dev',
                'libxkbcommon-dev',
                'libxkbcommon-x11-dev',
                'clang',
                'libclang-dev'
            )
        }
        i18n = [ordered]@{
            DisplayName = 'dx-i18n'
            CheckCommand = 'cargo check --locked --no-default-features --lib --bin dx-i18n'
            Dependencies = @()
            SystemPackages = @('libasound2-dev')
        }
        icon = [ordered]@{
            DisplayName = 'dx-icon'
            CheckCommand = 'cargo check --locked --lib --bins'
            Dependencies = @()
        }
        js = [ordered]@{
            DisplayName = 'dx-js'
            CheckCommand = 'cargo check --locked -p bun_bin --lib'
            Dependencies = @()
            AptSetupCommand = @'
curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | sudo tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc > /dev/null
echo "deb http://apt.llvm.org/$(lsb_release -cs)/ llvm-toolchain-$(lsb_release -cs)-21 main" | sudo tee /etc/apt/sources.list.d/llvm.list > /dev/null
'@
            SystemPackages = @('cmake', 'ninja-build', 'clang-21', 'lld-21', 'llvm-21', 'unzip')
            SetupCommand = @'
set -euo pipefail
if ! command -v bun >/dev/null 2>&1; then
  curl -fsSL https://bun.sh/install | bash -s "bun-v1.3.2"
  echo 'export PATH="$HOME/.bun/bin:$PATH"' >> "$BASH_ENV"
  export PATH="$HOME/.bun/bin:$PATH"
fi
bun --version
bun install --frozen-lockfile
bun scripts/build.ts --configure-only
ninja -C build/debug codegen clone-lolhtml
'@
        }
        media = [ordered]@{
            DisplayName = 'dx-media'
            CheckCommand = 'cargo check --locked --lib --bin media'
            Dependencies = @()
        }
        metasearch = [ordered]@{
            DisplayName = 'dx-metasearch'
            CheckCommand = 'cargo check --locked -p metasearch-cli --bin metasearch'
            Dependencies = @()
        }
        native = [ordered]@{
            DisplayName = 'dx-native'
            CheckCommand = 'cargo check --locked -p tauri-cli --bin cargo-tauri'
            Dependencies = @('serializer')
        }
        providers = [ordered]@{
            DisplayName = 'dx-providers'
            CheckCommand = 'cargo check --locked --bins'
            Dependencies = @()
        }
    }
}

function Get-DependencyRepositories {
    @{
        check = 'dx-check'
        dcp = 'dcp'
        serializer = 'dx-serializer'
        www = 'dx-www'
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

    $lines = @(
        'set -euo pipefail',
        "fallback_branch=`"$FallbackBranch`"",
        "default_owner=`"$Owner`"",
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
            if (-not $Repositories.ContainsKey($dependency)) {
                throw "No repository mapping is configured for dependency '$dependency'."
            }
            $lines += "clone_dx_dependency `"$dependency`" `"$($Repositories[$dependency])`""
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
    [string]::Join("`n", (($Text -split "`n") | ForEach-Object {
        if ($_ -eq '') {
            ''
        } else {
            "$prefix$_"
        }
    }))
}

function New-CircleCiConfig {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Profile,
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$FallbackBranch,
        [Parameter(Mandatory = $true)][string]$RustVersion
    )

    $displayName = [string]$Profile['DisplayName']
    $dependencies = @($Profile['Dependencies'] | ForEach-Object { [string]$_ })
    if ($Profile.Contains('SystemPackages')) {
        [string[]]$systemPackages = @($Profile['SystemPackages'] | ForEach-Object { [string]$_ })
    } else {
        [string[]]$systemPackages = @()
    }
    $repositories = Get-DependencyRepositories
    $dependencyCommand = Convert-ToIndentedBlock -Text (New-BashDependencyCommand -Dependencies $dependencies -Repositories $repositories -Owner $Owner -FallbackBranch $FallbackBranch)
    $checkCommand = Convert-ToIndentedBlock -Text ([string]$Profile['CheckCommand'])
    $systemPackageStep = ''
    $setupStep = ''

    if ($systemPackages.Count -gt 0) {
        $aptSetupCommand = if ($Profile.Contains('AptSetupCommand')) {
            [string]$Profile['AptSetupCommand']
        } else {
            ''
        }
        $systemPackageInstallCommand = Convert-ToIndentedBlock -Text @"
set -euo pipefail
$aptSetupCommand
sudo apt-get update
sudo apt-get install -y --no-install-recommends $($systemPackages -join ' ')
"@
        $systemPackageStep = @"
      - run:
          name: Install Linux system dependencies
          command: |
$systemPackageInstallCommand
"@
    }

    if ($Profile.Contains('SetupCommand')) {
        $setupCommand = Convert-ToIndentedBlock -Text ([string]$Profile['SetupCommand'])
        $setupStep = @"
      - run:
          name: Prepare repository build inputs
          command: |
$setupCommand
"@
    }

@"
version: 2.1

commands:
  prepare_unix_workspace:
    steps:
      - run:
          name: Checkout sibling Cargo dependencies
          command: |
$dependencyCommand

jobs:
  linux-check:
    docker:
      - image: cimg/rust:$RustVersion
    resource_class: small
    steps:
      - checkout
      - prepare_unix_workspace
$systemPackageStep
$setupStep
      - restore_cache:
          keys:
            - $displayName-cargo-{{ arch }}-{{ checksum "Cargo.lock" }}
            - $displayName-cargo-{{ arch }}-
      - run:
          name: Cargo metadata
          command: cargo metadata --locked --no-deps --format-version 1
      - run:
          name: Cargo check
          command: |
$checkCommand
      - save_cache:
          key: $displayName-cargo-{{ arch }}-{{ checksum "Cargo.lock" }}
          paths:
            - ~/.cargo/registry
            - ~/.cargo/git

workflows:
  validate:
    jobs:
      - linux-check:
          filters:
            branches:
              only:
                - main
                - $FallbackBranch
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
Write-Host "Wrote CircleCI check config for $Project to $OutputPath"

# Write .sr for serializer daemon
if ($dxConfig) {
    Write-DxSr -Path (Join-Path $dxConfig.SrDir "write-circleci-rust-check-config.sr") -Entries @{
        tool = "write-circleci-rust-check-config"
        action = "run"
        status = "ok"
    }
}
