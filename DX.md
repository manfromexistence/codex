# DX — Universal Project Config, Cache & Tool System

**Status:** Living document  
**Last updated:** 2026-07-03 (global cache section added)  
**Audience:** DX contributors, AI assistants, and tool implementers

This document describes the **DX Tool Contract** — three things every DX tool does in any project:

### 1. Read local `dx` config
Every DX tool discovers and reads the nearest `dx` extensionless config file (walks up from cwd). This file holds all project settings, paths, and cache roots in Serializer LLM format. No DX tool hardcodes paths — everything comes from `dx`.

### 2. Project cache → `.dx/` → `.sr` → `.machine`
Every DX tool stores project-specific state and caches in `.dx/` under the project root. Tools write state as `.sr` files (Serializer LLM format, human-readable). A daemon auto-compiles `.sr` → `.machine` (compiled RKYV + zstd, zero-copy mmap). Tools consume `.machine` for fast reads, falling back to `.sr` when needed.

### 3. Global state → `<DX_HOME>/` → `.sr` → `.machine`
Every DX tool stores machine-wide state under `<DX_HOME>/` — by default `%LOCALAPPDATA%/dx/` on Windows, `~/Library/Application Support/dx/` on macOS, `$XDG_DATA_HOME/dx/` or `~/.local/share/dx/` on Linux (overridable via `DX_HOME` env var or `paths.dx_home` in `dx`). Cache artifacts go under `<DX_HOME>/cache/`. Same pipeline: `.sr` write → auto-compile → `.machine` read. This keeps per-project folders clean and enables cross-project shared state (downloads, model weights, build artifacts, compiled indexes).

**The pipeline for all state:** `Tool writes state → .sr (LLM format) → auto-compile → .machine (fast mmap) → tool reads .machine`

The `G:\Dx` monorepo is the **first DX project** — we build and test the system here. When it works here, it works everywhere.

---

## 1. The Universal `dx` Config File

Every DX project has a `dx` file at its root (no extension, Serializer LLM format).

```
# Root dx file for the "DX" monorepo
workspace.name="DX"
workspace.root="G:/Dx"

paths.cli="cli"
paths.www="www"
paths.forge="forge"
paths.check="check"
paths.style="style"
paths.js="js"
paths.build="build"
paths.py="py"
paths.py_package_manager="py/package-manager"
paths.native="native"
paths.icon="icon"
paths.media="media"
paths.serializer="serializer"
paths.dx_agents="agent"
paths.inspirations="inspirations"

paths.cache=".dx/cache"
paths.cargo_home="cli/.cargo-home"

tools.scoop_root="G:/Dev/Tools/Scoop"
```

**Rules for tools:**
- Every DX tool **must** discover and read the nearest `dx` file (or its compiled `.machine`), walking upward from cwd if needed.
- Use it to resolve tool paths, project settings, and cache roots.
- DX tools that scaffold new projects **must** create a `dx` file in the new project root.

**Discovery:** Walk up from cwd until a `dx` file is found. The CLI currently implements this (skips project-style serializer tables, parses dotted keys via TOML compatibility). A reusable loader will serve all tools.

## 2. Serializer Formats — The Write/Compile/Read Pipeline

Defined in `serializer/`:

| Format | Extension | Use |
|--------|-----------|-----|
| **LLM format** | `*.llm` or extensionless | Authoring configs, writing cache artifacts as `.sr` files |
| **Human format** | (none) | Readable variant for debugging |
| **Machine format** | `.machine` | Compiled RKYV + zstd, zero-copy/mmap, fast reads |

**The Pipeline:**

```
Tool writes state  →  .sr (LLM format)  →  compile  →  .machine (for fast consumption)
```

- **Tools write `.sr` files** — LLM-format cache artifacts under `.dx/serializer/`
- **A watcher/daemon or build step** compiles `.sr` → `.machine`
- **Tools read `.machine`** for hot paths (configs, task state, receipts, metadata)
- Source `dx` files are also compiled to `.machine` for fast loading

See:
- `serializer/LLM_FORMAT_SPEC.md`
- `serializer/MACHINE_FORMAT.md`
- `serializer/docs/SERIALIZER.md`

## 3. `.dx/` Directory — Per-Project Cache Hub

Every DX project has a `.dx/` folder at its root. This is the **universal cache and receipt hub** for all DX tools operating in that project.

**Standard layout:**

```
.dx/
  receipts/<tool>/         # per-tool receipts
  serializer/              # .sr (LLM source) + .machine (compiled)
    *.sr                   # tool-written cache artifacts (LLM format)
    *.machine              # compiled fast artifacts
  <tool>/                  # per-tool machine caches (e.g. cli/, forge/)
```

**How tools use it:**
- Tools write state as `.sr` files under `.dx/serializer/` (LLM format).
- Compiled `.machine` files live alongside `.sr` sources in `.dx/serializer/`.
- Per-tool machine caches live under `.dx/<tool>/` for tool-specific fast state.
- **No hardcoded absolute paths** — all paths are relative to the project root or read from `dx`.

**In this monorepo (`G:\Dx`):**
The root `dx` defines `paths.cache=".dx/cache"`. Currently some absolute `G:\` paths remain — those should migrate to relatives. `.gitignore` protects `/.dx/*` except for a few intentional files.

**In any other project:**
Same layout. `dx` + `.dx/` + Serializer. Portable.

## 3a. Global State — `DX_HOME` Machine-Wide Root

Every DX tool stores **machine-wide state** outside the project tree under `DX_HOME`. This avoids duplicating large artifacts across projects and keeps `.dx/` lightweight.

**The `DX_HOME` environment variable** overrides the default root for all global DX state. If unset, the OS default is used:

| OS      | Default `DX_HOME` |
|---------|------------------|
| Windows | `%LOCALAPPDATA%/dx/` (e.g. `C:\Users\<you>\AppData\Local\dx\`) |
| macOS   | `~/Library/Application Support/dx/` |
| Linux   | `$XDG_DATA_HOME/dx/` or `~/.local/share/dx/` |

**Standard layout under `DX_HOME`:**
```
<DX_HOME>/
  bin/                    # installed DX binaries (added to PATH by installer)
    dx.exe
    dx-cli.exe
    dx-train.exe
    dx-diffusion.exe
    ...
  cache/                  # download caches, model weights, compiled indexes
    <tool>/               #   per-tool caches
      *.sr                #   tool-written cache artifacts (LLM format)
      *.machine           #   compiled fast artifacts
    serializer/           #   shared .sr → .machine daemon workspace
  config/                 # user configuration files
    dx.toml
  data/                   # application data (logs, databases, indexes)
    <tool>/               #   per-tool data
```

**Key points:**
- **Binaries** live in `bin/` under `DX_HOME` — never in the cache tree.
- **Cache** lives in `cache/` under `DX_HOME` — configurable via `paths.global_cache` in `dx`.
- **Config** lives in `config/` under `DX_HOME`.
- **Data** lives in `data/` under `DX_HOME`.
- The `paths.dx_home` key in `dx` overrides the default if set.
- The `paths.global_cache` key in `dx` overrides `<DX_HOME>/cache/` if set.

**Resolution order:**
1. `DX_HOME` env var (absolute path required)
2. `paths.dx_home` in the project `dx` file
3. OS default (see table above)

**When to use project vs global cache:**
| Cache in `.dx/` (project) | Cache in `<DX_HOME>/cache/` (global) |
|---|---|
| Per-project receipts, task state, build output | Downloaded models, SDKs, compiler caches |
| Tool-specific working state | Shared indexes, asset downloads |
| Checkpoint/analyze results | Cross-project reusable artifacts |

## 4. DX Tools Inventory

All folders at root **except** these are DX tools: `bin`, `web`, `website`, `mobile`, `zzz`.

Current DX tools (as of scan):
agent, check, cli, code, codex, dcp, diffusion, docs, driven, extensions, flow, forge, i18n, icon, js, logo, mcps, media, metasearch, native, providers, py, scripts, serializer, style, train, www

Special aliases / roles mentioned:
- `dx-js` ≈ `js/` (Bun fork)
- `dx-py` + `dx-py-package-manager` ≈ `py/` (CPython + uv)
- `dx-build` ≈ Rolldown experiments (paths.build declared; no top-level build/ tree yet)
- `dx diffusion` ≈ `diffusion/` (ComfyUI-based)
- `dx train` ≈ `train/` (Unsloth-based)

## 5. Integration Compliance Table

This table tracks how each DX tool in the monorepo (`G:\Dx`) implements the full contract: reads `dx`, writes `.sr`, consumes `.machine`, stores in `.dx/`, and writes global cache.

| Tool            | Reads `dx` | Writes `.sr` | Consumes `.machine` | Project `.dx/` | Global cache | Notes |
|-----------------|:----------:|:------------:|:-------------------:|:---------------:|:------------:|-------|
| check          | ✅ inline  | ✅ analyze   | ✅                  | Strong          | ✅ Phase 5   | Self-desc `check/dx` in LLM tables |
| cli            | ✅         | ✅           | ✅                  | Strong          | ✅ Phase 5   | `dx` discovery + `.dx/cli/*.machine` |
| dcp            | ✅ inline  | ✅ cli run   | ✅                  | Thin receipts   | ✅ Phase 5   | `read_status()` via `serializer::try_read_machine_or_sr` |
| diffusion      | ✅ Python  | ✅ start     | ❌ (Python)         | Partial         | ✅ Phase 5   | ComfyUI-based; .machine not in Python |
| driven         | ✅ dx-config | ✅ sync/analyze | ✅              | Thin receipts   | ✅ Phase 5   | `read_status()` via `dx-config` machine feature |
| flow           | ✅ inline  | ✅ cli run   | ✅                  | Thin receipts   | ✅ Phase 5   | `read_status()` via inline serializer |
| forge          | ✅ dx-config | ✅ commit   | ✅                  | Strong          | ✅ Phase 5   | `read_status()` via `dx-config` machine feature |
| i18n           | ✅ inline  | ✅ cli run   | ✅                  | Thin receipts   | ✅ Phase 5   | `read_status()` via `serializer::try_read_machine_or_sr` |
| icon           | ✅ inline  | ✅ cli run   | ✅                  | Thin receipts   | ✅ Phase 5   | `read_status()` via `serializer::try_read_machine_or_sr` |
| js             | ✅ inline  | ✅           | ✅ (pkg metadata)   | Partial         | ✅ Phase 5   | dx-js / Bun experiments |
| media          | ✅ inline  | ✅ cli run   | ✅                  | Thin receipts   | ✅ Phase 5   | `read_status()` via `serializer::try_read_machine_or_sr` |
| metasearch     | ✅ inline  | ✅ cli run   | ✅                  | Yes             | ✅ Phase 5   | `read_status()` via `serializer::try_read_machine_or_sr` |
| native         | ✅ inline  | ✅           | ✅ (opt-in)         | Partial         | ✅ Phase 5   | Machine cache experiments |
| providers      | ✅ inline  | ✅ cli run   | ✅                  | Thin receipts   | ✅ Phase 5   | `read_status()` via `serializer::try_read_machine_or_sr` |
| py             | ✅ inline  | ✅ now       | ✅ (machine directly)| Partial        | ✅ Phase 5   | dx-py + uv; .sr wiring added 2026-07-04 |
| serializer     | ✅ defines | ✅ core      | ✅ core             | Yes             | ✅ Phase 5   | `dx-sr-watch` daemon compiles `.sr` → `.machine` |
| style          | ✅ dx-config | ✅ save     | ✅                  | Yes             | ✅ Phase 5   | `read_status()` via `dx-config` machine feature |
| train          | ✅ Python  | ✅ cli run   | ❌ (Python)         | Partial         | ✅ Phase 5   | Unsloth-based; .machine not in Python |
| www            | ✅ dx-config | ✅ run      | ✅                  | Strong          | ✅ Phase 5   | Scaffolds projects with `dx` + `.dx/` |

**Current state (2026-07-04):**
- **All 19 tools** discover and read the project `dx` file on startup.
- **3 shared config loaders** exist: Rust (`serializer/crates/dx-config/`), Python (`scripts/dx_config.py`), PowerShell (`scripts/dx-config.psm1`).
- **`dx-sr-watch` daemon** built and tested — watches `.dx/serializer/*.sr`, auto-compiles to `.machine` + `.llm`.
- **Shared `.sr` writing utilities** created for all 3 languages.
- **19 of 19 tools write `.sr` artifacts** on state changes (py/ fixed 2026-07-04).
- **17 of 19 tools consume `.machine`** via `read_status()` fallback pattern (exceptions: diffusion, train — Python tools).
- **`dx-config` crate** has optional `machine` feature + `dx_home_dir()` / `global_cache_dir()` for path resolution.
- **`serializer` crate** exports `try_read_machine_or_sr()` utility for tools with direct serializer dep.
- **Global state shared utilities** created in Rust (`dx_config::dx_home_dir()`, `dx_config::global_cache_dir()`), Python (`DxConfig.dx_home_dir`, `DxConfig.global_cache_dir`), PowerShell (`Get-DxHomeDir`, `Get-DxGlobalCacheDir`).
- **All 19 tools wired** to write global `.sr` cache under `<DX_HOME>/cache/<tool>/`.
- **`paths.dx_home`** and **`paths.global_cache`** added to root `dx` config (empty = OS default).
- **Starter template** at `templates/dx-starter/` for new projects.

## 6. The Target — Every Tool in Every Project

When any project folder has `dx`, every DX tool should:

1. **Read `dx` config** — discover the nearest `dx` file (walk up from cwd). All paths, settings, and cache roots come from `dx`. No hardcoded paths.
2. **Write project cache as `.sr`** — store project-specific state under `.dx/serializer/` in LLM format.
3. **Write global cache as `.sr`** — store machine-wide state under `<DX_HOME>/cache/<tool>/` in LLM format.
4. **Consume `.machine`** — the `dx-sr-watch` daemon auto-compiles all `.sr` → `.machine` (zero-copy mmap). Tools read `.machine` for fast access, fall back to `.sr`.
5. **Store per-tool data** — project receipts/caches under `.dx/<tool>/`, global receipts under `<DX_HOME>/<tool>/`.
6. **Never hardcode paths** — all paths from `dx` or relative to project root / `<DX_HOME>`.

The `G:\Dx` monorepo is where we build and verify this contract. When it works here, it works for any project anywhere.

## 7. Current Gaps

- **`.sr` → `.machine` daemon runs** (`dx-sr-watch`) but isn't deployed as a system service yet.
- **17 of 19 tools consume `.machine`** via `read_status()` fallback. Diffusion and train (Python tools) are `.sr`-only — no `.machine` fast path (expected: Python doesn't have a Rust serializer FFI).
- **`py/` .sr writing** was fixed 2026-07-04 — now all 19 tools write `.sr`.
- **Starter template** at `templates/dx-starter/` ready for scaffolding.
- **Global state (`<DX_HOME>/`)** — Phase 5 implemented 2026-07-04. All 19 tools are wired with shared utilities in Rust, Python, and PowerShell. `dx-sr-watch` coverage of global paths is next.
- **Hardcoded paths** remain in some tools — not yet fully migrated to config-relative.

## 8. Roadmap

### ✅ Phase 1 (complete 2026-07-03): Universal Discovery

- [x] **Create reusable `dx` config loader** — Rust crate (`serializer/crates/dx-config/`), Python module (`scripts/dx_config.py`), PowerShell module (`scripts/dx-config.psm1`)
- [x] **Wire all 19 tools** to discover and read the project `dx` on startup
- [x] **Every tool creates `.dx/serializer/` and `.dx/receipts/<tool>/`** on startup
- [x] **Update compliance table** — all tools now read `dx`

### 🔄 Phase 2 (near complete): .sr Writing & .machine Consumption

- [x] **Build `.sr` → `.machine` daemon** (`dx-sr-watch`) — watches `.dx/serializer/*.sr` and auto-compiles
- [x] **Create shared `.sr` writing utilities** — Rust (`dx_config::write_sr_file`), Python (`write_sr`), PowerShell (`Write-DxSr`)
- [x] **Wire 17 tools to write `.sr` caches** — check, cli, dcp, diffusion, driven, flow, forge, i18n, icon, js, media, metasearch, native, providers, serializer, style, train, www
- [x] **Wire Rust tools to consume `.machine`** via `read_status()` fallback pattern
- [x] **Add `.machine` reading utility** to `serializer` crate (`try_read_machine_or_sr`) and `dx-config` crate (`read_machine_or_sr`)
- [x] **Wire .sr for non-Rust tools** — py, diffusion, train (Python-based)
- [x] **Publish `dx-config` crate** so git-dep tools can switch from inline to shared lib

### ✅ Phase 3 (complete 2026-07-03): Hardcoded Path Removal

- [x] **Remove hardcoded `G:\Dx` paths** — replaced hardcoded paths in `cli/` (update_manifest test URL)
- [x] **Audit all 19 tools** for hardcoded paths — migrate to config-relative

### 🏗️ Phase 4: Automation & Enforcement

- [x] **Add `dx` + `.dx/` starter template** for new projects scaffolded by DX tools
- [x] **Gate new tools** — they must implement the contract from day one
- [x] **Publish `dx-config` crate** to crates.io or as a proper git dep

### ✅ Phase 5: Global State (`<DX_HOME>/`) — Complete 2026-07-04

- [x] **Add `paths.dx_home` and `paths.global_cache` to root `dx`** with fallback to OS default
- [x] **Create shared path resolvers** in Rust (`dx_config::dx_home_dir()`, `dx_config::global_cache_dir()`), Python (`DxConfig.dx_home_dir`, `DxConfig.global_cache_dir`), PowerShell (`Get-DxHomeDir`, `Get-DxGlobalCacheDir`)
- [ ] **Wire `dx-sr-watch`** to also watch `<DX_HOME>/cache/<tool>/*.sr` for auto-compile
- [ ] **Add `paths.dx_home` to starter template** at `templates/dx-starter/`
- [ ] **Migrate one tool** (e.g. `cli`) to store downloads/indexes in global cache as reference implementation
- [x] **Expand compliance table** with a "Global cache" column

## 9. Tool Enforcement Queue — Verified: All 3 Rules Complete

All 19 tools have been verified for the full **3-rule contract**:

1. ✅ **Read `dx` config** — discover and parse the nearest `dx` file
2. ✅ **Write project cache** — `.dx/serializer/<tool>.sr` → `.machine` pipeline
3. ✅ **Write global cache** — `<DX_HOME>/cache/<tool>/<tool>.sr` via shared utility

| # | Tool | Read `dx` | `.sr` → `.machine` | Global cache (`<DX_HOME>/cache/<tool>/`) |
|---|------|:---------:|:------------------:|:-------------------------------------:|
| 1 | `check/` | ✅ | ✅ | ✅ |
| 2 | `cli/` | ✅ | ✅ | ✅ |
| 3 | `dcp/` | ✅ | ✅ | ✅ |
| 4 | `diffusion/` | ✅ | ⚠️ .sr only (Python) | ✅ |
| 5 | `driven/` | ✅ | ✅ | ✅ |
| 6 | `flow/` | ✅ | ✅ | ✅ |
| 7 | `forge/` | ✅ | ✅ | ✅ |
| 8 | `i18n/` | ✅ | ✅ | ✅ |
| 9 | `icon/` | ✅ | ✅ | ✅ |
| 10 | `js/` | ✅ | ✅ | ✅ |
| 11 | `media/` | ✅ | ✅ | ✅ |
| 12 | `metasearch/` | ✅ | ✅ | ✅ |
| 13 | `native/` | ✅ | ✅ | ✅ |
| 14 | `providers/` | ✅ | ✅ | ✅ |
| 15 | `py/` | ✅ | ✅ (.machine + .sr fixed) | ✅ |
| 16 | `serializer/` | ✅ (defines) | ✅ | ✅ |
| 17 | `style/` | ✅ | ✅ | ✅ |
| 18 | `train/` | ✅ | ⚠️ .sr only (Python) | ✅ |
| 19 | `www/` | ✅ | ✅ | ✅ |

- `diffusion/` and `train/` are Python-based and don't have Rust `.machine` consumption — acceptable per spec.
- All other 17 tools have full `.sr` → `.machine` pipeline.
- All 19 tools write global `.sr` cache via shared utilities.

## Related Files

- `dx` — this project's `dx` config (Serializer LLM format)
- `serializer/LLM_FORMAT_SPEC.md`, `serializer/MACHINE_FORMAT.md`
- `serializer/docs/SERIALIZER.md`
- `serializer/crates/dx-config/` — **Reusable Rust `dx-config` crate** (shared across tools)
- `scripts/dx_config.py` — **Reusable Python `dx_config` module**
- `scripts/dx-config.psm1` — **Reusable PowerShell dx-config module**
- `cli/src/config.rs` — original `dx` loader implementation (reference)
- `.dx/` — this project's cache hub (gitignored)
- `GROK.md` — high-level tool inventory

---

## Agent Handoff Summary (for AI agents picking up this task)

### What Phase 1 accomplished
All 19 tools discover and read the project `dx` file on startup:

- **Rust tools**: Added `dx-config` dep or inline `dx_config.rs` module
- **Python tools** (`diffusion`, `train`, `py`): Added `dx_config.py` + startup wiring
- Each tool creates `.dx/serializer/` and `.dx/receipts/<tool>/` at startup

### What Phase 2 has accomplished
- **`dx-sr-watch` daemon** built at `serializer/src/bin/watch_daemon.rs` — watches `.dx/serializer/*.sr`, auto-compiles to `.machine` + `.llm`
- **Shared `.sr` writing utilities** in all 3 languages:
  - Rust: `dx_config::write_sr_file()` in `serializer/crates/dx-config/src/lib.rs`
  - Python: `write_sr()` in `scripts/dx_config.py`
  - PowerShell: `Write-DxSr` in `scripts/dx-config.psm1`
- **19 of 19 tools wired** to write `.sr` on state changes (py/ fixed 2026-07-04)
- **`.machine` consumption wired in Rust tools** via `read_status()` fallback pattern:
  - **Fast path** (`.machine` via serializer): forge, style, check, driven, www, flow, cli
  - **Slow path** (`.sr` only): providers, media, icon, metasearch, dcp, i18n
- **Shared `.machine` reading utilities**:
  - `serializer::try_read_machine_or_sr()` — full fast path for tools with serializer dep
  - `dx_config::read_machine_or_sr()` — optional `machine` feature on `dx-config` crate

### ✅ Phase 5 Complete — Global State (`<DX_HOME>/`)

Phase 5 added the third pillar: **machine-wide state root** outside the project tree.

**What was accomplished (2026-07-05):**
- ✅ Add `paths.dx_home` and `paths.global_cache` to root `dx` with OS-default fallback
- ✅ Create shared resolvers in Rust (`dx_config::dx_home_dir()`, `dx_config::global_cache_dir()`), Python (`DxConfig.dx_home_dir`, `DxConfig.global_cache_dir`), PowerShell (`Get-DxHomeDir`, `Get-DxGlobalCacheDir`)
- ✅ Add computed `bin_dir()`, `config_dir()`, `data_dir()` properties to all loaders
- ✅ Wire all 19 tools to write global `.sr` cache (`<DX_HOME>/cache/<tool>/<tool>.sr`)
- ✅ Fix `py/` `.sr` writing (was the last tool missing it)
- ✅ Expand compliance table with "Global cache" column

**Still to do:**
- [ ] Wire `dx-sr-watch` to also watch `<DX_HOME>/cache/<tool>/*.sr`
- [ ] Add to starter template
- [ ] Migrate one tool (e.g. `cli`) as reference implementation

### Shared module locations
| Language | Location | How to use |
|----------|----------|------------|
| Rust | `serializer/crates/dx-config/` | `dx-config = { path = "../serializer/crates/dx-config" }` in Cargo.toml |
| Python | `scripts/dx_config.py` | Copy to tool's dir, `from dx_config import DxConfig` |
| PowerShell | `scripts/dx-config.psm1` | `Import-Module ...\dx-config.psm1` then `Get-DxConfig` |

**This document tracks compliance. Update it when a tool gains or loses `dx` + `.sr` + `.machine` + `.dx/` integration.**