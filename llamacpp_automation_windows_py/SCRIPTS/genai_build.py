from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

from _native import apply_dependency_paths, apply_proxy_env_from_config, dependency_root, ensure_dir, ensure_tool, load_config, project_root, resolve_path, run_cmd


def venv_python(venv_root: Path) -> Path:
    if os.name == "nt":
        return venv_root / "Scripts" / "python.exe"
    return venv_root / "bin" / "python"


def parse_auto_update(cfg: dict) -> bool:
    top = cfg.get("auto_update")
    if top is not None:
        return str(top).strip().lower() in {"true", "1", "yes"}
    ll_cfg = cfg.get("llamacpp", {}) or {}
    return str(ll_cfg.get("auto_update", "true")).strip().lower() in {"true", "1", "yes"}


def load_logged_commit(log_file: Path) -> str:
    if not log_file.is_file():
        return ""
    lines = log_file.read_text(encoding="utf-8", errors="ignore").splitlines()
    if not lines:
        return ""
    return lines[0].split()[0].strip()


def write_commit_log(git: str, repo_dir: Path, log_file: Path, env: dict[str, str]) -> None:
    full_commit = run_cmd([git, "-C", str(repo_dir), "rev-parse", "HEAD"], env=env, capture_output=True).stdout.strip()
    short = full_commit[:9]
    subject = run_cmd([git, "-C", str(repo_dir), "log", "-1", "--format=%s"], env=env, capture_output=True).stdout.strip()
    ensure_dir(log_file.parent)
    log_file.write_text(f"{short} {subject}\n", encoding="utf-8")


def remove_tree_with_retries(path: Path, retries: int = 4) -> bool:
    if not path.exists():
        return True
    for _ in range(retries):
        try:
            shutil.rmtree(path)
        except Exception:
            pass
        if not path.exists():
            return True
    return not path.exists()


def genai_ready(repo_dir: Path) -> bool:
    bench_dir = repo_dir / "tools" / "llm_bench"
    venv_dir = bench_dir / "python-env"
    py = venv_python(venv_dir)
    bench_script = bench_dir / "benchmark.py"
    req_file = bench_dir / "requirements.txt"
    return bench_dir.is_dir() and venv_dir.is_dir() and py.is_file() and bench_script.is_file() and req_file.is_file()


def main() -> int:
    root = project_root(__file__)
    cfg = load_config(root)
    env = dict(os.environ)
    apply_proxy_env_from_config(cfg, env)
    dep_root = dependency_root(root, cfg)
    ensure_dir(dep_root)
    apply_dependency_paths(dep_root, env)

    build_dir = resolve_path(root, cfg.get("build_dir"), "./BUILD")
    logs_dir = resolve_path(root, cfg.get("logs_dir"), "./logs")
    repo_dir = build_dir / "openvino.genai"
    bench_dir = repo_dir / "tools" / "llm_bench"
    venv_dir = bench_dir / "python-env"

    ll_mode = str((cfg.get("llamacpp", {}) or {}).get("use", "build")).strip().lower()
    genai_log = logs_dir / f"openvino_genai_commit_{ll_mode}.txt"

    auto_update = parse_auto_update(cfg)
    print(f"auto_update={auto_update} (openvino.genai)")

    ensure_dir(build_dir)
    ensure_dir(logs_dir)
    git_exe = ensure_tool("git", dep_root, env)

    remote_head = ""
    if auto_update:
        remote_head = run_cmd(
            [git_exe, "ls-remote", "https://github.com/openvinotoolkit/openvino.genai.git", "HEAD"],
            env=env,
            capture_output=True,
        ).stdout.split()[0].strip()

    logged = load_logged_commit(genai_log)
    remote_short = remote_head[: len(logged)] if logged and remote_head else ""
    same_commit = True
    if auto_update:
        same_commit = bool(logged and remote_short == logged)

    ready = genai_ready(repo_dir)
    full_rebuild = not same_commit
    build_missing = not ready

    if full_rebuild:
        print("GenAI plan: commit changed or missing, rebuild openvino.genai setup")
    elif build_missing:
        print("GenAI plan: incremental, setup missing prerequisites")
    else:
        print("GenAI plan: up to date, skip setup")

    if full_rebuild and repo_dir.exists():
        if not remove_tree_with_retries(repo_dir):
            print(f"Warning: failed to clean openvino.genai directory (locked), falling back to in-place sync: {repo_dir}")
            if auto_update and remote_head:
                try:
                    run_cmd([git_exe, "-C", str(repo_dir), "fetch", "--all", "--tags", "--prune"], env=env)
                    run_cmd([git_exe, "-C", str(repo_dir), "reset", "--hard", remote_head], env=env)
                    run_cmd([git_exe, "-C", str(repo_dir), "clean", "-fdx"], env=env, check=False)
                    print("GenAI in-place sync completed")
                except Exception as exc:
                    print(f"Warning: GenAI in-place sync failed, continuing with existing repo state ({exc})")

    if not full_rebuild and not build_missing:
        if repo_dir.is_dir():
            write_commit_log(git_exe, repo_dir, genai_log, env)
        print("GenAI build/setup completed (no changes)")
        return 0

    if not repo_dir.is_dir():
        run_cmd([git_exe, "clone", "https://github.com/openvinotoolkit/openvino.genai.git", str(repo_dir)], env=env)

    if not bench_dir.is_dir():
        raise RuntimeError(f"Missing llm_bench directory: {bench_dir}")

    if not venv_dir.is_dir():
        run_cmd([sys.executable, "-m", "venv", str(venv_dir)], cwd=bench_dir, env=env)

    py = venv_python(venv_dir)
    if not py.is_file():
        raise RuntimeError(f"Venv python not found: {py}")

    run_cmd([str(py), "-m", "pip", "install", "--upgrade", "pip"], cwd=bench_dir, env=env)
    req_file = bench_dir / "requirements.txt"
    if req_file.is_file():
        run_cmd([str(py), "-m", "pip", "install", "-r", str(req_file)], cwd=bench_dir, env=env)
    run_cmd([str(py), "-m", "pip", "install", "transformers==4.55.4", "diffusers<0.35"], cwd=bench_dir, env=env)

    write_commit_log(git_exe, repo_dir, genai_log, env)

    print("GenAI build/setup completed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
