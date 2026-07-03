"""DX config discovery and loading for Python tools.

Usage:
    from dx_config import DxConfig
    config = DxConfig.discover()
    print(config.workspace_root)
    print(config.path("cli"))
"""

import os
import re
from pathlib import Path
from typing import Optional


class DxConfig:
    """Represents a parsed DX project config from an extensionless `dx` file."""

    def __init__(self, root: Path):
        self.workspace_root = root.resolve()
        self._paths: dict[str, Path] = {}
        self._settings: dict[str, str] = {}

    @classmethod
    def discover(cls, cwd: Optional[Path] = None) -> "DxConfig":
        """Discover and load dx config, walking up from cwd."""
        dx_home = os.environ.get("DX_HOME")
        if dx_home:
            home = Path(dx_home).resolve()
            dx_file = home / "dx"
            if dx_file.is_file():
                return cls._load(dx_file)
            return cls(home)

        cwd = cwd or Path.cwd()
        dx_file = cls._discover_file(cwd)
        if dx_file is None:
            return cls(cwd)
        return cls._load(dx_file)

    @classmethod
    def _discover_file(cls, start: Path) -> Optional[Path]:
        """Walk up from start looking for an extensionless `dx` file."""
        for ancestor in [start] + list(start.parents):
            candidate = ancestor / "dx"
            if candidate.is_file() and not cls._looks_like_project_config(candidate):
                return candidate
        return None

    @classmethod
    def _load(cls, path: Path) -> "DxConfig":
        """Parse a dx file and return a DxConfig."""
        config = cls(path.parent)
        source = path.read_text(encoding="utf-8")
        for line in source.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r'^([a-zA-Z_][\w.]*)\s*=\s*"([^"]*)"$', line)
            if m:
                key, value = m.group(1), m.group(2)
                config._settings[key] = value
        return config

    @staticmethod
    def _looks_like_project_config(path: Path) -> bool:
        """Check if a dx file is a project-level Serializer config (not workspace)."""
        try:
            source = path.read_text(encoding="utf-8")
        except Exception:
            return False
        for line in source.splitlines():
            stripped = line.strip().lstrip("\ufeff")
            if not stripped or stripped.startswith("#"):
                continue
            if any(
                stripped.startswith(p)
                for p in ("project(", "contract(", "runtime(", "www(")
            ):
                return True
            if "[" in stripped and "(" in stripped:
                return True
            break
        return False

    def path(self, key: str) -> Path:
        """Resolve a path from config, relative to workspace root."""
        raw = self._settings.get(f"paths.{key}")
        if raw is None:
            return self.workspace_root / key
        p = Path(raw)
        return p if p.is_absolute() else (self.workspace_root / p)

    @property
    def cache_dir(self) -> Path:
        return self.path("cache")

    @property
    def sr_dir(self) -> Path:
        return self.cache_dir.parent / "serializer"

    def get(self, key: str, default: str = "") -> str:
        return self._settings.get(key, default)

    def __repr__(self) -> str:
        return f"DxConfig(root={self.workspace_root})"


def _needs_quoting(value: str) -> bool:
    """Check if a value needs quoting in DX LLM format."""
    if not value:
        return True
    special = {'"', '[', ']', '=', '#'}
    return any(c.isspace() or c in special for c in value)


def _escape_llm(value: str) -> str:
    """Escape a string for DX LLM format quoting."""
    return value.replace("\\", "\\\\").replace('"', '\\"')


def write_sr(path: Path, entries: dict[str, str]) -> None:
    """Write a .sr file in DX LLM format (key=value pairs).

    The serializer daemon (dx-sr-watch) auto-compiles .sr -> .machine.
    Call this to persist tool state for fast runtime loading.

    Args:
        path: Output .sr file path (e.g., Path(".dx/serializer/forge-cache.sr"))
        entries: Flat key-value pairs to write.

    Example:
        write_sr(
            Path(".dx/serializer/forge-cache.sr"),
            {"name": "forge", "version": "1.0.0", "status": "ready"},
        )
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    for key, value in entries.items():
        if _needs_quoting(value):
            lines.append(f'{key}="{_escape_llm(value)}"')
        else:
            lines.append(f"{key}={value}")
    content = "\n".join(lines) + "\n"
    # Atomic write via temp file
    tmp = path.with_suffix(".sr.tmp")
    tmp.write_text(content, encoding="utf-8")
    tmp.rename(path)
