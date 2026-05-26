from __future__ import annotations

import glob
import importlib
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Any

_PROJECT_GUESS = Path(__file__).resolve().parent.parent


def _proxy_env_from_raw_config(config_file: Path) -> dict[str, str]:
    if not config_file.is_file():
        return {}

    text = config_file.read_text(encoding="utf-8", errors="ignore")
    if not re.search(r"^\s*use_proxy:\s*true\s*$", text, flags=re.IGNORECASE | re.MULTILINE):
        return {}

    env: dict[str, str] = {}
    for key, val in re.findall(r"^\s*-\s*([A-Za-z_][A-Za-z0-9_]*)=(.+)$", text, flags=re.MULTILINE):
        env[key.strip()] = val.strip()
    return env


def _ensure_python_package(module_name: str, package_name: str) -> None:
    if importlib.util.find_spec(module_name) is not None:
        return

    install_env = dict(os.environ)
    install_env.update(_proxy_env_from_raw_config(_PROJECT_GUESS / "config.yaml"))
    cmd = [sys.executable, "-m", "pip", "install", "--disable-pip-version-check", package_name]
    proxy = install_env.get("HTTPS_PROXY") or install_env.get("https_proxy") or install_env.get("HTTP_PROXY") or install_env.get("http_proxy")
    if proxy:
        cmd += ["--proxy", proxy]

    # First attempt uses normal certificate validation.
    completed = subprocess.run(cmd, env=install_env)
    if completed.returncode == 0:
        return

    # Some enterprise proxies MITM TLS and break certificate validation.
    retry_cmd = [
        *cmd,
        "--trusted-host",
        "pypi.org",
        "--trusted-host",
        "files.pythonhosted.org",
        "--trusted-host",
        "pypi.python.org",
    ]
    completed = subprocess.run(retry_cmd, env=install_env)
    if completed.returncode != 0:
        raise RuntimeError(f"Failed to install Python package {package_name}")


_ensure_python_package("yaml", "PyYAML")
_ensure_python_package("requests", "requests")

import yaml  # noqa: E402
import requests  # noqa: E402


def project_root(script_file: str) -> Path:
    return Path(script_file).resolve().parent.parent


def load_config(project_dir: Path) -> dict[str, Any]:
    cfg_path = project_dir / "config.yaml"
    if not cfg_path.is_file():
        raise FileNotFoundError(f"Missing config file: {cfg_path}")
    with cfg_path.open("r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    return data


def resolve_path(project_dir: Path, value: str | None, default_rel: str) -> Path:
    raw = value or default_rel
    p = Path(raw)
    if p.is_absolute():
        return p
    return (project_dir / raw).resolve()


def ensure_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def apply_proxy_env_from_config(cfg: dict[str, Any], env: dict[str, str]) -> None:
    proxy_cfg = cfg.get("proxy") or {}
    use_proxy = str(proxy_cfg.get("use_proxy", "false")).strip().lower()
    if use_proxy not in {"true", "1", "yes"}:
        return

    for line in proxy_cfg.get("proxy_list", []) or []:
        line = str(line).strip()
        if not line:
            continue
        if line.lower().startswith("export "):
            line = line[7:].strip()
        if "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip()
        if key:
            env[key] = val


def dependency_root(project_dir: Path, cfg: dict[str, Any]) -> Path:
    dep = cfg.get("dependency_dir")
    return resolve_path(project_dir, str(dep) if dep else None, "./DEPENDENCIES")


def dependency_path_entries(dep_root: Path) -> list[Path]:
    return [
        dep_root / "bin",
        dep_root / "cmake" / "bin",
        dep_root / "ninja",
        dep_root / "python",
        dep_root / "w64devkit" / "bin",
        dep_root / "git" / "cmd",
        dep_root / "git" / "usr" / "bin",
    ]


def apply_dependency_paths(dep_root: Path, env: dict[str, str]) -> None:
    items = [str(p) for p in dependency_path_entries(dep_root) if p.is_dir()]
    if not items:
        return
    existing = env.get("PATH", "")
    env["PATH"] = os.pathsep.join(items + [existing]) if existing else os.pathsep.join(items)


def run_cmd(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    check: bool = True,
    capture_output: bool = False,
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        capture_output=capture_output,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"Command failed ({proc.returncode}): {' '.join(cmd)}\n"
            f"stdout:\n{proc.stdout or ''}\n"
            f"stderr:\n{proc.stderr or ''}"
        )
    return proc


def download_file(url: str, dest: Path, env: dict[str, str] | None = None) -> None:
    ensure_dir(dest.parent)
    proxies = None
    if env:
        proxies = {
            "http": env.get("HTTP_PROXY") or env.get("http_proxy"),
            "https": env.get("HTTPS_PROXY") or env.get("https_proxy"),
        }
    with requests.get(url, stream=True, timeout=120, proxies=proxies) as r:
        r.raise_for_status()
        with dest.open("wb") as fh:
            for chunk in r.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    fh.write(chunk)


def _extract_zip(src: Path, dst: Path) -> None:
    ensure_dir(dst)
    with zipfile.ZipFile(src, "r") as zf:
        zf.extractall(dst)


def _run_self_extract(exe: Path, dst: Path, env: dict[str, str]) -> None:
    ensure_dir(dst)
    cmd = [str(exe), "-y", f"-o{dst}"]
    run_cmd(cmd, env=env)


def ensure_tool(name: str, dep_root: Path, env: dict[str, str]) -> str:
    try:
        return find_executable(name, dep_root)
    except FileNotFoundError:
        pass

    if name == "ninja":
        zip_path = dep_root / "ninja" / "ninja-win.zip"
        download_file("https://github.com/ninja-build/ninja/releases/latest/download/ninja-win.zip", zip_path, env)
        try:
            _extract_zip(zip_path, dep_root / "ninja")
        finally:
            if zip_path.exists():
                zip_path.unlink(missing_ok=True)
    elif name == "cmake":
        zip_path = dep_root / "cmake" / "cmake-win.zip"
        download_file("https://github.com/Kitware/CMake/releases/download/v3.30.5/cmake-3.30.5-windows-x86_64.zip", zip_path, env)
        tmp = dep_root / "cmake_extract"
        try:
            if tmp.exists():
                shutil.rmtree(tmp, ignore_errors=True)
            _extract_zip(zip_path, tmp)
            dirs = [d for d in tmp.iterdir() if d.is_dir()]
            if not dirs:
                raise RuntimeError("Failed to extract CMake")
            target = dep_root / "cmake"
            ensure_dir(target)
            src = dirs[0]
            for child in src.iterdir():
                dst = target / child.name
                if dst.exists():
                    if dst.is_dir():
                        shutil.rmtree(dst, ignore_errors=True)
                    else:
                        dst.unlink()
                if child.is_dir():
                    shutil.copytree(child, dst)
                else:
                    shutil.copy2(child, dst)
        finally:
            if tmp.exists():
                shutil.rmtree(tmp, ignore_errors=True)
            if zip_path.exists():
                zip_path.unlink(missing_ok=True)
    elif name == "git":
        pkg = dep_root / "git_pkg" / "portablegit.7z.exe"
        download_file("https://github.com/git-for-windows/git/releases/download/v2.49.0.windows.1/PortableGit-2.49.0-64-bit.7z.exe", pkg, env)
        try:
            _run_self_extract(pkg, dep_root / "git", env)
        finally:
            if pkg.exists():
                pkg.unlink(missing_ok=True)
    else:
        raise FileNotFoundError(f"Tool auto-bootstrap not implemented: {name}")

    apply_dependency_paths(dep_root, env)
    return find_executable(name, dep_root)


def find_executable(name: str, dep_root: Path | None = None) -> str:
    if dep_root is not None:
        candidates = {
            "git": [dep_root / "git" / "cmd" / "git.exe", dep_root / "git" / "usr" / "bin" / "git.exe"],
            "cmake": [dep_root / "cmake" / "bin" / "cmake.exe"],
            "ninja": [dep_root / "ninja" / "ninja.exe"],
            "python": [dep_root / "python" / "python.exe"],
            "python3": [dep_root / "python" / "python.exe"],
            "optimum-cli": [Path(sys.executable).parent / "optimum-cli.exe", Path(sys.executable).parent / "optimum-cli"],
        }
        for cand in candidates.get(name, []):
            if cand.is_file():
                return str(cand)

    resolved = shutil.which(name)
    if resolved:
        return resolved
    raise FileNotFoundError(f"Required executable not found: {name}")


def latest_matching(path_glob: str) -> Path | None:
    matches = sorted(glob.glob(path_glob), key=os.path.getmtime, reverse=True)
    return Path(matches[0]) if matches else None
