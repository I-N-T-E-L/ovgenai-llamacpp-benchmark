from __future__ import annotations

import csv
import re
import sys
from pathlib import Path

from _native import latest_matching, load_config, project_root, resolve_path


def build_missing_hf_report(cfg: dict, root: Path) -> list[list[str]]:
    ir_root = resolve_path(root, cfg.get("ir_dir"), "./MODELS/ir")
    models = (cfg.get("ir_models") or {}).get("models") or []
    defaults_devices = (cfg.get("defaults") or {}).get("devices") or []
    devices = [str(d).strip().upper() for d in defaults_devices if str(d).strip()]
    if not devices:
        devices = ["GPU", "NPU"]
    devices = [d for d in devices if d in {"GPU", "NPU"}]

    configured_count = 0
    missing_items: list[str] = []
    seen: set[str] = set()

    for model in models:
        model = str(model).strip()
        if not model:
            continue
        safe_name = model.split("/", 1)[-1].replace("/", "__")
        for device in devices:
            expected = ir_root / device / safe_name / "openvino_model.xml"
            key = str(expected)
            if key in seen:
                continue
            seen.add(key)
            configured_count += 1
            if not expected.is_file():
                missing_items.append(f"{device}/{safe_name}")

    header_rows = [
        ["#"],
        ["# === HF MODEL PRESENCE CHECK ==="],
        [f"# hf_root: {ir_root}"],
        [f"# configured_device_models: {configured_count}"],
        [f"# missing_device_models: {len(missing_items)}"],
    ]

    if not missing_items:
        header_rows.append(["# missing_hf_model: NONE"])
    else:
        for item in missing_items:
            header_rows.append([f"# missing_hf_model: {item}"])
    header_rows.append([])
    return header_rows


def main() -> int:
    root = project_root(__file__)
    cfg = load_config(root)
    results_dir = resolve_path(root, cfg.get("results_dir"), "./RESULTS")
    input_file = Path(sys.argv[1]) if len(sys.argv) > 1 else latest_matching(str(results_dir / "genaibench_*.txt"))
    if not input_file or not input_file.is_file():
        raise RuntimeError("No genaibench_*.txt found to parse")

    output_csv = input_file.with_suffix(".csv")
    rows: list[list[str]] = []
    device = ""
    model = ""
    pit = ""
    ttft = ""
    tps = ""
    input_tokens = ""

    with input_file.open("r", encoding="utf-8", errors="ignore") as fh:
        for raw in fh:
            line = raw.strip()
            if line.startswith(">> Device:"):
                if any([device, model, pit, ttft, tps, input_tokens]):
                    rows.append([model, device, pit, input_tokens, ttft, tps])
                device = line.split(":", 1)[1].strip()
                model = ""
                pit = ttft = tps = input_tokens = ""
                continue
            if line.startswith(">> Model Dir:"):
                model = Path(line.split(":", 1)[1].strip()).name
                continue

            m = re.search(r"Pipeline initialization time:\s*([0-9.]+)", line)
            if m:
                pit = m.group(1)
            m = re.search(r"Input token size:\s*([0-9]+)", line)
            if m:
                input_tokens = m.group(1)
            m = re.search(r"1st token latency:\s*([0-9.]+)", line)
            if m:
                ttft = m.group(1)
            m = re.search(r"2nd tokens throughput:\s*([0-9.]+)", line)
            if m:
                tps = m.group(1)

    if any([device, model, pit, ttft, tps, input_tokens]):
        rows.append([model, device, pit, input_tokens, ttft, tps])

    if not rows:
        raise RuntimeError(f"No benchmark frames found in {input_file}")

    with output_csv.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerows(build_missing_hf_report(cfg, root))
        writer.writerow(["Model", "Device", "PIT_s", "InputTokenSize", "TTFT_ms", "TPS"])
        writer.writerows(rows)

    print(f"Input:  {input_file}")
    print(f"Output: {output_csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
