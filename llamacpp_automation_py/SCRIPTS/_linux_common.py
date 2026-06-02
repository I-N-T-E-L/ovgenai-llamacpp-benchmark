#!/usr/bin/env python3
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
CONFIG_FILE = PROJECT_ROOT / "config.yaml"


def _proxy_env_from_raw_config(config_file: Path) -> dict[str, str]:
    if not config_file.is_file():
        return {}

    text = config_file.read_text(encoding="utf-8", errors="ignore")
    if "use_proxy" not in text:
        return {}

    env: dict[str, str] = {}
    enabled = False
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.lower().startswith("use_proxy:"):
            enabled = line.split(":", 1)[1].strip().lower() in {"true", "1", "yes", "y", "on"}
        if line.startswith("-") and "=" in line:
            entry = line[1:].strip()
            if entry.lower().startswith("export "):
                entry = entry[7:].strip()
            key, val = entry.split("=", 1)
            key = key.strip()
            val = val.strip()
            if key:
                env[key] = val

    return env if enabled else {}


def _ensure_pkg(module_name: str, package_name: str) -> None:
    try:
        __import__(module_name)
        return
    except Exception:
        pass

    install_env = dict(os.environ)
    install_env.update(_proxy_env_from_raw_config(CONFIG_FILE))

    cmd = [sys.executable, "-m", "pip", "install", "--disable-pip-version-check", package_name]
    proxy = (
        install_env.get("HTTPS_PROXY")
        or install_env.get("https_proxy")
        or install_env.get("HTTP_PROXY")
        or install_env.get("http_proxy")
    )
    if proxy:
        cmd += ["--proxy", proxy]

    rc = subprocess.run(cmd, env=install_env).returncode
    if rc != 0:
        retry_cmd = [
            *cmd,
            "--trusted-host",
            "pypi.org",
            "--trusted-host",
            "files.pythonhosted.org",
            "--trusted-host",
            "pypi.python.org",
        ]
        rc = subprocess.run(retry_cmd, env=install_env).returncode
        if rc != 0:
            raise RuntimeError(f"Failed to install required package: {package_name}")


_ensure_pkg("yaml", "PyYAML")
_ensure_pkg("requests", "requests")
import yaml  # noqa: E402


def load_config() -> dict[str, Any]:
    if not CONFIG_FILE.is_file():
        raise FileNotFoundError(f"Missing config file: {CONFIG_FILE}")
    with CONFIG_FILE.open("r", encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def resolve_path(raw: str | None) -> Path:
    if not raw:
        return PROJECT_ROOT
    p = Path(str(raw))
    if p.is_absolute():
        return p
    return (PROJECT_ROOT / str(raw).lstrip("./")).resolve()


def to_bool(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    return str(value).strip().lower() in {"1", "true", "yes", "y", "on"}


def apply_optional_proxy(cfg: dict[str, Any], env: dict[str, str]) -> None:
    proxy_cfg = cfg.get("proxy") or {}
    if not to_bool(proxy_cfg.get("use_proxy"), False):
        return

    for line in proxy_cfg.get("proxy_list") or []:
        txt = str(line).strip()
        if not txt:
            continue
        if txt.lower().startswith("export "):
            txt = txt[7:].strip()
        if "=" not in txt:
            continue
        key, val = txt.split("=", 1)
        key = key.strip()
        val = val.strip()
        if key:
            env[key] = val


def run_capture(cmd: list[str], *, env: dict[str, str] | None = None) -> tuple[int, str]:
    proc = subprocess.run(cmd, text=True, capture_output=True, env=env)
    out = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, out.strip()


def run_stream(cmd: list[str], *, env: dict[str, str] | None = None, cwd: Path | None = None) -> int:
    proc = subprocess.run(cmd, env=env, cwd=str(cwd) if cwd else None)
    return proc.returncode


def shell_exists(name: str) -> bool:
    return shutil.which(name) is not None
