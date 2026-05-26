from __future__ import annotations

import csv
import subprocess
import sys
from datetime import datetime
from time import perf_counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCRIPTS_DIR = ROOT / "SCRIPTS"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from _native import load_config, resolve_path


def _ts() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def run_step(script_name: str, index: int, total: int, args: list[str] | None = None) -> None:
    args = args or []
    script_path = SCRIPTS_DIR / script_name
    command = [sys.executable, str(script_path), *args]
    print(f"\n[{_ts()}] [{index}/{total}] Starting step: {script_name}")
    print(f"[{_ts()}] Command: {' '.join(command)}")
    print(f"[{_ts()}] Working dir: {ROOT}")
    started = perf_counter()
    completed = subprocess.run(command)
    elapsed = perf_counter() - started
    if completed.returncode == 0:
        print(f"[{_ts()}] [{index}/{total}] Step succeeded: {script_name} ({elapsed:.1f}s)")
    else:
        print(f"[{_ts()}] [{index}/{total}] Step failed: {script_name} ({elapsed:.1f}s), exit={completed.returncode}")
    if completed.returncode != 0:
        raise SystemExit(completed.returncode)


def latest_csv(results_dir: Path, prefix: str) -> Path | None:
    matches = sorted(results_dir.glob(f"{prefix}_*.csv"), key=lambda p: p.stat().st_mtime, reverse=True)
    return matches[0] if matches else None


def merge_csvs(llama_csv: Path | None, genai_csv: Path | None, out_csv: Path) -> None:
    with out_csv.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)

        if llama_csv and llama_csv.is_file():
            with llama_csv.open("r", encoding="utf-8", errors="ignore") as lf:
                for row in csv.reader(lf):
                    writer.writerow(row)

        if genai_csv and genai_csv.is_file():
            with genai_csv.open("r", encoding="utf-8", errors="ignore") as gf:
                for row in csv.reader(gf):
                    writer.writerow(row)


def main() -> int:
    root = ROOT
    cfg = load_config(root)
    results_dir = resolve_path(root, cfg.get("results_dir"), "./RESULTS")
    results_dir.mkdir(parents=True, exist_ok=True)

    steps = [
        "llamacpp_build.py",
        "gguf_downloader.py",
        "llamacpp_bench.py",
        "llamacpp_parser.py",
        "genai_build.py",
        "ovir_downloader.py",
        "genai_bench.py",
        "genai_parser.py",
    ]

    print(f"[{_ts()}] Unified run started")
    print(f"[{_ts()}] Python: {sys.executable}")
    print(f"[{_ts()}] Scripts dir: {SCRIPTS_DIR}")
    print(f"[{_ts()}] Results dir: {results_dir}")
    print(f"[{_ts()}] Total steps: {len(steps)}")

    for i, step in enumerate(steps, start=1):
        run_step(step, i, len(steps))

    llama_csv = latest_csv(results_dir, "llamabench")
    genai_csv = latest_csv(results_dir, "genaibench")
    out_csv = root / f"result_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
    merge_csvs(llama_csv, genai_csv, out_csv)
    print(f"[{_ts()}] Unified CSV: {out_csv}")
    print(f"[{_ts()}] Unified run completed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
