#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONFIG_FILE = ROOT / "config.yaml"


def _select_scripts_dir() -> Path:
    scripts = ROOT / "SCRIPTS"
    if scripts.is_dir():
        return scripts

    raise RuntimeError("Missing scripts directory: expected ./SCRIPTS")


SCRIPTS_DIR = _select_scripts_dir()
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from _linux_common import load_config, resolve_path  # noqa: E402


def _workflow_step_candidates() -> list[str]:
    # Keep this order aligned with the legacy shell runner.
    return [
        "llamacpp_build.py",
        "gguf_downloader.py",
        "llamacpp_bench.py",
        "llamacpp_parser.py",
        "genai_build.py",
        "ovir_downloader.py",
        "genai_bench.py",
        "genai_parser.py",
    ]


def _latest_csv(results_dir: Path, prefix: str) -> Path | None:
    matches = sorted(results_dir.glob(f"{prefix}_*.csv"), key=lambda p: p.stat().st_mtime, reverse=True)
    return matches[0] if matches else None


def _run_step(script_name: str, label: str) -> None:
    script_path = SCRIPTS_DIR / script_name
    if not script_path.is_file():
        raise RuntimeError(f"Missing script for {label}: {script_path}")

    print(f"\n=== Running: {label} ===")
    cmd = [sys.executable, str(script_path)]
    rc = subprocess.run(cmd, cwd=str(ROOT)).returncode
    if rc != 0:
        raise SystemExit(rc)


def _append_text(dst: Path, text: str) -> None:
    with dst.open("a", encoding="utf-8") as fh:
        fh.write(text)


def _preflight_check() -> int:
    if not CONFIG_FILE.is_file():
        print(f"Error: Missing config file: {CONFIG_FILE}")
        return 1

    cfg = load_config()
    results_raw = cfg.get("results_dir")
    if not results_raw:
        print(f"Error: Missing results_dir in {CONFIG_FILE}")
        return 1

    results_dir = resolve_path(str(results_raw))
    missing_scripts = [name for name in _workflow_step_candidates() if not (SCRIPTS_DIR / name).is_file()]
    if missing_scripts:
        for item in missing_scripts:
            print(f"Error: Missing script in workflow: {SCRIPTS_DIR / item}")
        return 1

    print("Preflight check passed.")
    print(f"Scripts dir: {SCRIPTS_DIR}")
    print(f"Results dir (resolved): {results_dir}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Unified llama/genai benchmark workflow runner")
    parser.add_argument("--check", action="store_true", help="Validate config and required scripts, then exit")
    args = parser.parse_args()

    os.chdir(ROOT)

    if hasattr(os, "geteuid") and os.geteuid() == 0:
        print("Error: Do not run this script with sudo.")
        print("Run as normal user; privileged steps will escalate with sudo when needed.")
        return 1

    if not CONFIG_FILE.is_file():
        print(f"Error: Missing config file: {CONFIG_FILE}")
        return 1

    if args.check:
        return _preflight_check()

    cfg = load_config()
    results_raw = cfg.get("results_dir")
    if not results_raw:
        print(f"Error: Missing results_dir in {CONFIG_FILE}")
        return 1

    results_dir = resolve_path(str(results_raw))
    results_dir.mkdir(parents=True, exist_ok=True)

    print("Starting unified llama.cpp benchmark workflow...")

    _run_step("llamacpp_build.py", "llama.cpp Install/Build (includes dependency install + OpenVINO setup)")

    # Backward-compatible filename resolution for gguf_downloadr.py typo.
    if (SCRIPTS_DIR / "gguf_downloadr.py").is_file():
        _run_step("gguf_downloadr.py", "GGUF Downloader")
    else:
        _run_step("gguf_downloader.py", "GGUF Downloader")

    _run_step("llamacpp_bench.py", "llama.cpp Benchmark")
    _run_step("llamacpp_parser.py", "Benchmark Parser")

    llama_csv = _latest_csv(results_dir, "llamabench")
    if llama_csv is None:
        print(f"Warning: No llama CSV file found in {results_dir} after llama parser step")

    _run_step("genai_build.py", "GenAI Build")
    _run_step("ovir_downloader.py", "OV IR Downloader")
    _run_step("genai_bench.py", "GenAI Benchmark")
    _run_step("genai_parser.py", "GenAI Parser")

    genai_csv = _latest_csv(results_dir, "genaibench")
    if genai_csv is None:
        print(f"Warning: No GenAI CSV file found in {results_dir} after GenAI parser step")

    run_timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    unified_csv = ROOT / f"result_{run_timestamp}.csv"

    if llama_csv is not None:
        shutil.copyfile(llama_csv, unified_csv)
        _append_text(unified_csv, f"\n# --- Base CSV: {llama_csv.name} ---\n")
    elif genai_csv is not None:
        shutil.copyfile(genai_csv, unified_csv)
        _append_text(unified_csv, f"\n# --- Base CSV: {genai_csv.name} ---\n")
    else:
        print(f"Error: Neither llamabench_*.csv nor genaibench_*.csv found in {results_dir}")
        return 1

    if llama_csv is not None and genai_csv is not None:
        if llama_csv.resolve() != genai_csv.resolve():
            _append_text(unified_csv, f"\n# --- Appended GenAI CSV: {genai_csv.name} ---\n")
            _append_text(unified_csv, genai_csv.read_text(encoding="utf-8", errors="ignore"))
    elif llama_csv is None:
        _append_text(unified_csv, "\n# --- Note: llama CSV missing; unified file contains only GenAI CSV. ---\n")
    elif genai_csv is None:
        _append_text(unified_csv, "\n# --- Note: GenAI CSV missing; unified file contains only llama CSV. ---\n")

    print(f"\nCopied unified CSV to script directory: {unified_csv}")
    print("Workflow complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
