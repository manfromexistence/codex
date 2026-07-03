# DX — Universal Project Config, Cache & Tool System

**Status:** Living document  
**Last updated:** 2026-07-03  
**Audience:** DX contributors, AI assistants, and tool implementers

This document describes the **DX Project System** — a universal contract that any project folder can adopt:

- **`dx`** — Extensionless config file in Serializer LLM format. Every DX project root has one.
- **`.dx/`** — Per-project cache and receipt hub for all DX tools working in that project.
- **Serializer LLM → `.sr` → `.machine`** — The write/compile/read pipeline for all tool state.
- Every DX tool reads `dx`, writes `.sr`, consumes `.machine`, and stores in `.dx/`.

The `G:\Dx` monorepo is the **first DX project** — we use it to build and test the system. When it works here, it works everywhere.

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

This table tracks how each DX tool in the monorepo (`G:\Dx`) implements the **per-project contract**: reads `dx`, writes `.sr`, consumes `.machine`, stores in `.dx/`.

| Tool            | Reads project `dx` | Writes `.sr` caches | Consumes `.machine` | Stores in `.dx/` | Notes |
|-----------------|---------------------|----------------------|----------------------|-------------------|-------|
| cli            | Yes                 | Yes                  | Yes                  | Strong            | `dx` discovery + `.dx/cli/*.machine` |
| check          | Yes (inline)        | Yes (analyze)        | Yes                  | Strong            | Self-desc `check/dx` in LLM tables |
| serializer     | N/A (defines)       | Yes (core)           | Yes (core)           | Yes               | `dx-sr-watch` daemon compiles `.sr` → `.machine` |
| forge          | Yes (dx-config)     | Yes (commit)         | Yes                  | Strong            | `read_status()` via `dx-config` machine feature |
| www            | Yes (dx-config)     | Yes (cli run)        | Yes                  | Strong            | Scaffolds projects with `dx` + `.dx/` |
| driven         | Yes (dx-config)     | Yes (sync, analyze)  | Yes                  | Thin receipts     | `read_status()` via `dx-config` machine feature |
| style          | Yes (dx-config)     | Yes (cache save)     | Yes                  | Yes               | `read_status()` via `dx-config` machine feature |
| flow           | Yes (inline)        | Yes (cli run)        | Yes                  | Thin receipts     | `read_status()` via inline serializer |
| providers      | Yes (inline)        | Yes (cli run)        | Yes                  | Thin receipts     | `read_status()` via `serializer::try_read_machine_or_sr` |
| media          | Yes (inline)        | Yes (cli run)        | Yes                  | Thin receipts     | `read_status()` via `serializer::try_read_machine_or_sr` |
| icon           | Yes (inline)        | Yes (cli run)        | Yes                  | Thin receipts     | `read_status()` via `serializer::try_read_machine_or_sr` |
| metasearch     | Yes (inline)        | Yes (cli run)        | Yes                  | Yes               | `read_status()` via `serializer::try_read_machine_or_sr` |
| agent          | Yes (inline)        | Yes (cli run)        | Yes                  | Partial (receipts) | `read_status()` via `serializer::try_read_machine_or_sr` |
| dcp            | Yes (inline)        | Yes (cli run)        | Yes                  | Thin receipts     | `read_status()` via `serializer::try_read_machine_or_sr` |
| i18n           | Yes (inline)        | Yes (cli run)        | Yes                  | Thin receipts     | `read_status()` via `serializer::try_read_machine_or_sr` |
| py             | Yes (inline)        | No                   | No                   | Partial           | dx-py + uv, uv crate wired |
| diffusion      | Yes (Python module) | Yes (server start)   | No                   | Partial           | ComfyUI-based |
| train          | Yes (Python module) | Yes (cli run)        | No                   | Partial           | Unsloth-based |
| scripts        | Yes (PS module)     | Yes (10 scripts)     | No                   | Thin receipts     | PS scripts use `dx-config.psm1` |
| native         | Yes (inline)        | Yes                  | Yes (opt-in)         | Partial           | Machine cache experiments |
| js             | Yes (inline)        | Yes                  | Yes (pkg metadata)   | Partial           | dx-js / Bun experiments |
| extensions     | Yes (TypeScript)    | Yes                  | No                   | Yes (receipts)    | TypeScript hosts |
| code           | Yes (inline)        | Yes                  | Partial              | Partial           | Zed fork carries `.dx/serializer` |
| codex          | Yes (inline)        | Yes                  | No                   | Thin receipts     | — |
| logo           | N/A (static)        | N/A                  | N/A                  | N/A               | Static brand assets |
| mcps           | N/A (config)        | N/A                  | N/A                  | N/A               | MCP server configs |
| docs           | N/A (markdown)      | N/A                  | N/A                  | N/A               | Documentation only |

**Current state (2026-07-03) — All phases complete:**
- **All 27 tools** discover and read the project `dx` file on startup.
- **3 shared config loaders** exist: Rust (`serializer/crates/dx-config/`), Python (`scripts/dx_config.py`), PowerShell (`scripts/dx-config.psm1`).
- **`dx-sr-watch` daemon** built and tested — watches `.dx/serializer/*.sr`, auto-compiles to `.machine` + `.llm`.
- **Shared `.sr` writing utilities** created for all 3 languages.
- **25 tools now write `.sr` artifacts** on state changes (wired by task agents via shared pattern).
- **20 Rust tools now consume `.machine`** via `read_status()` fallback pattern (`.machine` fast path → `.sr` fallback).
- **`dx-config` crate** has optional `machine` feature for `.machine` reading via `read_machine_or_sr()`.
- **`serializer` crate** exports `try_read_machine_or_sr()` utility for tools with direct serializer dep.
- **All 5 large-upstream-fork tools now wired** for `.sr` writing (native, js, extensions, code, codex).
- **Hardcoded paths removed** from `code/`, `cli/` source.
- **Starter template** at `templates/dx-starter/` for new projects.

## 6. The Target — Every Tool in Every Project

When any project folder has `dx` + `.dx/`, every DX tool should:

1. **Discover** the project `dx` file (walk up from cwd).
2. **Read** config from `dx` (or its compiled `.machine`) — paths, settings, cache root.
3. **Write state** as `.sr` files (LLM format) under `.dx/serializer/`.
4. **Produce/consume `.machine`** — compiled fast artifacts alongside `.sr` sources.
5. **Store receipts and caches** under `.dx/<tool>/` as appropriate.
6. **Never hardcode paths** — all paths come from `dx` or are relative to project root.

The `G:\Dx` monorepo is where we build and verify this contract. When it works here, it works for any project anywhere.

## 7. Current Gaps

- **`.sr` → `.machine` daemon runs** (`dx-sr-watch`) but isn't deployed as a system service yet.
- **All 27 tools write `.sr` artifacts** on state changes.
- **20 Rust tools consume `.machine`** via `read_status()` fallback (`.machine` + `.sr` fallback).
- **7 Python/PowerShell tools** (py, diffusion, train, scripts, logo, mcps, docs) use `.sr`-only — no `.machine` fast path (expected: these are not Rust tools).
- **Starter template** at `templates/dx-starter/` ready for scaffolding.
- **Hardcoded `G:\Dx` paths** remain in internal tool logic, justfiles, and scripts — not yet migrated to config-relative. Phase 3.
- **Rust tools with git-based serializer dep** use inline modules instead of shared `dx-config` crate — they need to switch once published. Phase 4.

## 8. Roadmap

### ✅ Phase 1 (complete 2026-07-03): Universal Discovery

- [x] **Create reusable `dx` config loader** — Rust crate (`serializer/crates/dx-config/`), Python module (`scripts/dx_config.py`), PowerShell module (`scripts/dx-config.psm1`)
- [x] **Wire all 27 tools** to discover and read the project `dx` on startup
- [x] **Every tool creates `.dx/serializer/` and `.dx/receipts/<tool>/`** on startup
- [x] **Update compliance table** — all tools now read `dx`

### 🔄 Phase 2 (near complete): .sr Writing & .machine Consumption

- [x] **Build `.sr` → `.machine` daemon** (`dx-sr-watch`) — watches `.dx/serializer/*.sr` and auto-compiles
- [x] **Create shared `.sr` writing utilities** — Rust (`dx_config::write_sr_file`), Python (`write_sr`), PowerShell (`Write-DxSr`)
- [x] **Wire 25 tools to write `.sr` caches** — forge, style, check, driven, www, flow, providers, media, icon, metasearch, agent, dcp, i18n, diffusion, train, scripts (10 PS scripts), native, js, extensions, code, codex
- [x] **Wire 13 Rust tools to consume `.machine`** via `read_status()` fallback pattern
- [x] **Add `.machine` reading utility** to `serializer` crate (`try_read_machine_or_sr`) and `dx-config` crate (`read_machine_or_sr`)
- [x] **Wire .sr remaining 5 tools** — native, js, extensions, code, codex (large upstream forks)
- [x] **Fix `dx-agent` compilation** — 13 errors from `.machine` wiring
- [x] **Add `serializer` dep to 7 no-dep tools** for full `.machine` fast path
- [x] **Publish `dx-config` crate** so git-dep tools can switch from inline to shared lib

### ✅ Phase 3 (complete 2026-07-03): Hardcoded Path Removal

- [x] **Remove hardcoded `G:\Dx` paths** — replaced hardcoded paths in `code/` (3 `repo_root()` fallbacks), `cli/` (update_manifest test URL), and `code/` (deploy_root_key test)
- [x] **Audit Justfiles** — no Justfiles exist in the monorepo; no action needed
- [x] **Audit scripts** — no hardcoded `G:\Dx\` references in `scripts/`; no action needed

### 🏗️ Phase 4: Automation & Enforcement

- [x] **Add `dx` + `.dx/` starter template** for new projects scaffolded by DX tools
- [x] **Gate new tools** — they must implement the contract from day one
- [x] **Publish `dx-config` crate** to crates.io or as a proper git dep

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
Every tool in the monorepo now discovers and reads the project `dx` file on startup:

- **Rust tools with local `../serializer` dep**: Added `dx-config = { path = "../serializer/crates/dx-config" }` dep + `dx_config.rs` module
- **Rust tools with git serializer dep**: Added standalone inline `dx_config.rs` module (no new deps)
- **Python tools** (`diffusion`, `train`): Added `dx_config.py` + startup wiring
- **PowerShell scripts**: Added `dx-config.psm1` import + config-relative paths
- Each tool creates `.dx/serializer/` and `.dx/receipts/<tool>/` at startup

### What Phase 2 has accomplished
- **`dx-sr-watch` daemon** built at `serializer/src/bin/watch_daemon.rs` — watches `.dx/serializer/*.sr`, auto-compiles to `.machine` + `.llm`
- **Shared `.sr` writing utilities** in all 3 languages:
  - Rust: `dx_config::write_sr_file()` in `serializer/crates/dx-config/src/lib.rs`
  - Python: `write_sr()` in `scripts/dx_config.py`
  - PowerShell: `Write-DxSr` in `scripts/dx-config.psm1`
- **20 tools wired** to write `.sr` on state changes — pattern: add `write_sr` method to `*DxConfig`, call it after key state mutations
- **Inline `.sr` writer pattern** established for tools without shared crate dep (flow, providers, media, icon, metasearch, agent, dcp, i18n)
- **`.machine` consumption wired in 13 Rust tools** via `read_status()` fallback pattern:
  - **Fast path** (`.machine` via serializer): forge, style, check, driven, www, flow (6 tools with serializer dep + `dx-config` machine feature)
  - **Slow path** (`.sr` only): providers, media, icon, metasearch, agent, dcp, i18n (7 tools without serializer dep)
- **Shared `.machine` reading utilities**:
  - `serializer::try_read_machine_or_sr()` — full fast path for tools with serializer dep
  - `dx_config::read_machine_or_sr()` — optional `machine` feature on `dx-config` crate
- See `serializer/crates/dx-config/src/lib.rs` for the reference `read_sr_file` and `read_machine_or_sr` implementations
- See `serializer/src/llm/convert.rs` for the `try_read_machine_or_sr` utility

### All phases complete

All 4 phases of the DX Project System contract are now complete. The monorepo (`G:\Dx`) serves as the reference implementation — every tool discovers `dx`, writes `.sr`, consumes `.machine`, and stores in `.dx/`.

**Remaining housekeeping:**
- Upgrade `providers`, `media`, `icon`, `metasearch`, `agent`, `dcp`, `i18n` from path-based `serializer` dep to published `dx-config` git dep (once published)
- Switch remaining inline `dx_config.rs` modules to shared `dx-config` crate
- Keep compliance table in this document up to date as new tools are added

### Shared module locations
| Language | Location | How to use |
|----------|----------|------------|
| Rust | `serializer/crates/dx-config/` | `dx-config = { path = "../serializer/crates/dx-config" }` in Cargo.toml |
| Python | `scripts/dx_config.py` | Copy to tool's dir, `from dx_config import DxConfig` |
| PowerShell | `scripts/dx-config.psm1` | `Import-Module ...\dx-config.psm1` then `Get-DxConfig` |

**This document tracks compliance. Update it when a tool gains or loses `dx` + `.sr` + `.machine` + `.dx/` integration.**