from __future__ import annotations

import csv
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from _native import latest_matching, load_config, project_root, resolve_path


@dataclass
class MetricRow:
    model: str
    size_value: str
    size_unit: str
    params_value: str
    params_unit: str
    backend: str
    d: str
    p: str
    n: str
    pp_mean: str
    pp_stddev: str
    tg_mean: str
    tg_stddev: str
    error: str


def extract_semver(text: str) -> str:
    m = re.search(r"([0-9]+\.[0-9]+\.[0-9]+)", text)
    return m.group(1) if m else ""


def split_value_unit(text: str) -> tuple[str, str]:
    parts = text.strip().split()
    if len(parts) < 2:
        return text.strip(), ""
    return parts[0], parts[1]


def split_tps(text: str) -> tuple[str, str]:
    normalized = text.strip().replace("Â±", "±").replace("Â", "")
    parts = re.split(r"\s*±\s*", normalized)
    def num_or_raw(src: str) -> str:
        m = re.search(r"[-+]?\d+(?:\.\d+)?", src)
        return m.group(0) if m else src.strip()
    if len(parts) < 2:
        return num_or_raw(normalized), ""
    return num_or_raw(parts[0]), num_or_raw(parts[1])


def parse_test_fields(test: str) -> tuple[str, str, str]:
    t = test.strip().lower()
    kind = ""
    val = ""
    d = "0"

    m = re.match(r"^(pp|tg)(\d+)", t)
    if m:
        kind = m.group(1)
        val = m.group(2)

    dm = re.search(r"@\s*d(\d+)", t)
    if dm:
        d = dm.group(1)

    return kind, val, d


def resolve_ov_runtime_version(root: Path, cfg: dict, use_mode: str) -> tuple[str, str]:
    if use_mode != "build":
        return "N/A", "N/A"

    dep_root = resolve_path(root, cfg.get("dependency_dir"), "./DEPENDENCIES")
    ov_root = dep_root / "openvino"
    if (ov_root / "setupvars.bat").is_file():
        runtime_root = ov_root
    else:
        hits = sorted(ov_root.rglob("setupvars.bat")) if ov_root.exists() else []
        runtime_root = hits[-1].parent if hits else None

    if runtime_root is None:
        return "N/A", "N/A"

    source = str(runtime_root / "runtime" / "version.txt")
    vf = runtime_root / "runtime" / "version.txt"
    if not vf.is_file():
        return source, "N/A"

    line = vf.read_text(encoding="utf-8", errors="ignore").splitlines()
    first = line[0].strip() if line else ""
    sem = extract_semver(first)
    return source, (sem or first or "N/A")


def build_missing_gguf_report(root: Path, cfg: dict) -> list[str]:
    lines: list[str] = []
    lines.append("#")
    lines.append("# === GGUF MODEL PRESENCE CHECK ===")

    gguf_root = resolve_path(root, cfg.get("gguf_dir"), "./MODELS/gguf")
    quant_items = (cfg.get("llamacpp", {}) or {}).get("quantizations", []) or []
    if not quant_items:
        lines.append("# [No llamacpp.quantizations entries found]")
        return lines

    gguf_models = cfg.get("gguf_models", {}) or {}
    configured_count = 0
    missing_items: list[str] = []
    seen: set[str] = set()

    for q in quant_items:
        quant = str(q).strip()
        if not quant:
            continue
        entries = gguf_models.get(quant, []) or []
        for entry in entries:
            raw = str(entry).strip()
            if not raw:
                continue

            if raw.startswith("http://") or raw.startswith("https://"):
                name = raw.split("/")[-1].split("?")[0]
                expected = gguf_root / quant / name
                label = f"{quant}/{name}"
            else:
                p = Path(raw)
                if p.is_absolute():
                    expected = p
                    label = str(p)
                else:
                    expected = gguf_root / quant / p.name
                    label = f"{quant}/{p.name}"

            key = str(expected)
            if key in seen:
                continue
            seen.add(key)
            configured_count += 1
            if not expected.is_file():
                missing_items.append(label)

    lines.append(f"# gguf_root: {gguf_root}")
    lines.append(f"# configured_models: {configured_count}")
    lines.append(f"# missing_models: {len(missing_items)}")
    if not missing_items:
        lines.append("# missing_model: NONE")
    else:
        for item in missing_items:
            lines.append(f"# missing_model: {item}")
    return lines


def sys_config_block(root: Path) -> list[str]:
    lines: list[str] = []
    script = root / "SCRIPTS" / "sys_config.py"
    if not script.is_file():
        lines.append("# [Missing script: SCRIPTS/sys_config.py]")
        return lines

    proc = subprocess.run([sys.executable, str(script)], cwd=str(root), capture_output=True, text=True)
    text = (proc.stdout or "") + (proc.stderr or "")

    skip_ov = False
    for raw in text.splitlines():
        line = raw.rstrip("\r")
        if line.strip() == "=== OPENVINO DETAILS ===":
            skip_ov = True
            continue
        if skip_ov:
            if not line.strip():
                skip_ov = False
            continue
        lines.append(f"# {line}" if line else "#")
    return lines


def parse_metrics(input_file: Path) -> list[MetricRow]:
    rows: list[MetricRow] = []
    current_model = ""
    current_backend = ""
    current_ov_device = ""

    pp_rows: dict[tuple[str, str, str, str, str, str, str, str], list[tuple[str, str, str]]] = {}
    tg_rows: dict[tuple[str, str, str, str, str, str, str, str], list[tuple[str, str, str]]] = {}

    with input_file.open("r", encoding="utf-8", errors="ignore") as fh:
        for raw in fh:
            line = raw.strip("\n")

            if line.startswith(">> Model:"):
                current_model = line.split(":", 1)[1].strip()
                current_model = re.sub(r"\.gguf$", "", current_model)
                continue

            if line.startswith(">> Executing:"):
                cmd = line
                current_ov_device = ""
                if "ReleaseVulkan" in cmd:
                    current_backend = "Vulkan"
                elif "ReleaseOV" in cmd:
                    m = re.search(r"GGML_OPENVINO_DEVICE=([^\s]+)", cmd)
                    current_ov_device = m.group(1).strip('"') if m else ""
                    current_backend = f"OV-{current_ov_device}" if current_ov_device else "OPENVINO"
                elif "Release/" in cmd or "Release\\" in cmd:
                    current_backend = "BARE-CPU"
                else:
                    current_backend = ""
                continue

            if not line.strip().startswith("|"):
                continue

            parts = [p.strip() for p in line.split("|")]
            if len(parts) < 4:
                continue
            cols = [c for c in parts[1:-1]]
            if not cols:
                continue

            if cols[0].lower() == "model":
                continue
            if re.fullmatch(r"-+", cols[0]):
                continue

            # Table shape differs by backend. OPENVINO rows add the extra 'fa' column.
            # Use fixed indexes for early columns and tail indexes for test/tps.
            if len(cols) >= 7:
                c_model = cols[0]
                c_size = cols[1]
                c_params = cols[2]
                c_backend = cols[3]
                c_test = cols[-2]
                c_tps = cols[-1]
            else:
                continue

            if not current_model:
                current_model = c_model

            backend = c_backend
            if c_backend.upper() == "OPENVINO" and current_ov_device:
                backend = f"OV-{current_ov_device}"
            elif c_backend.upper() == "CPU":
                backend = "BARE-CPU"
            elif not backend:
                backend = current_backend

            size_val, size_unit = split_value_unit(c_size)
            params_val, params_unit = split_value_unit(c_params)
            mean, std = split_tps(c_tps)
            kind, test_val, d = parse_test_fields(c_test)
            if kind not in {"pp", "tg"}:
                continue

            key = (current_model, size_val, size_unit, params_val, params_unit, backend, d, current_backend)
            entry = (test_val, mean, std)
            if kind == "pp":
                pp_rows.setdefault(key, []).append(entry)
            else:
                tg_rows.setdefault(key, []).append(entry)

    for key, p_list in pp_rows.items():
        t_list = tg_rows.get(key, [])
        if not t_list:
            continue

        p_sorted = sorted(p_list, key=lambda x: int(x[0]) if x[0].isdigit() else 0)
        t_sorted = sorted(t_list, key=lambda x: int(x[0]) if x[0].isdigit() else 0)
        n = min(len(p_sorted), len(t_sorted))
        model, sv, su, pv, pu, backend, d, _ = key

        for i in range(n):
            p = p_sorted[i]
            t = t_sorted[i]
            rows.append(
                MetricRow(
                    model=model,
                    size_value=sv,
                    size_unit=su,
                    params_value=pv,
                    params_unit=pu,
                    backend=backend,
                    d=d,
                    p=p[0],
                    n=t[0],
                    pp_mean=p[1],
                    pp_stddev=p[2],
                    tg_mean=t[1],
                    tg_stddev=t[2],
                    error="",
                )
            )

    if rows:
        return rows

    # Preserve frames that contain no metric lines as error rows.
    fallback_rows: list[MetricRow] = []
    current_model = "UNKNOWN_MODEL"
    current_backend = ""
    notes: list[str] = []

    with input_file.open("r", encoding="utf-8", errors="ignore") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if line.startswith(">> Model:"):
                current_model = line.split(":", 1)[1].strip() or "UNKNOWN_MODEL"
            elif line.startswith(">> Executing:"):
                if notes:
                    fallback_rows.append(
                        MetricRow(current_model, "", "", "", "", current_backend, "", "", "", "", "", "", "", " | ".join(notes))
                    )
                    notes = []
                if "ReleaseVulkan" in line:
                    current_backend = "Vulkan"
                elif "ReleaseOV" in line:
                    m = re.search(r"GGML_OPENVINO_DEVICE=([^\s]+)", line)
                    current_backend = f"OV-{m.group(1).strip('"')}" if m else "OPENVINO"
                elif "Release/" in line or "Release\\" in line:
                    current_backend = "BARE-CPU"
                else:
                    current_backend = ""
            elif line and not line.startswith(">>") and not line.startswith("-") and not line.strip().startswith("|"):
                notes.append(line.strip())

    if notes:
        fallback_rows.append(MetricRow(current_model, "", "", "", "", current_backend, "", "", "", "", "", "", "", " | ".join(notes)))

    return fallback_rows


def main() -> int:
    root = project_root(__file__)
    cfg = load_config(root)
    results_dir = resolve_path(root, cfg.get("results_dir"), "./RESULTS")

    input_file = Path(sys.argv[1]) if len(sys.argv) > 1 else latest_matching(str(results_dir / "llamabench_*.txt"))
    if not input_file or not input_file.is_file():
        raise RuntimeError(f"No llamabench_*.txt found in {results_dir}")

    output_csv = input_file.with_suffix(".csv")
    llm = cfg.get("llamacpp", {}) or {}
    use_mode = str(llm.get("use", "build")).strip().lower()
    logs_dir = resolve_path(root, cfg.get("logs_dir"), "./logs")
    commit_file = logs_dir / f"llama_cpp_commit_{use_mode}.txt"

    ov_source, ov_version = resolve_ov_runtime_version(root, cfg, use_mode)
    rows = parse_metrics(input_file)

    with output_csv.open("w", encoding="utf-8", newline="") as fh:
        for line in sys_config_block(root):
            fh.write(line + "\n")

        fh.write("#\n")
        fh.write("# === LLAMA_CPP LATEST COMMIT HASH & COMMENT ===\n")
        if commit_file.is_file():
            first = commit_file.read_text(encoding="utf-8", errors="ignore").splitlines()
            fh.write(f"# {(first[0].strip() if first else 'N/A')}\n")
        else:
            fh.write("# N/A\n")

        if use_mode == "build":
            fh.write("#\n")
            fh.write("# === OPENVINO VERSION ===\n")
            fh.write(f"# mode: {use_mode}\n")
            fh.write(f"# source: {ov_source}\n")
            fh.write(f"# version: {ov_version}\n")

        for line in build_missing_gguf_report(root, cfg):
            fh.write(line + "\n")

        writer = csv.writer(fh)
        writer.writerow([
            "Model",
            "SizeValue",
            "SizeUnit",
            "ParamsValue",
            "ParamsUnit",
            "Backend",
            "D",
            "P",
            "N",
            "PP_Mean",
            "PP_StdDev",
            "TG_Mean",
            "TG_StdDev",
            "Error",
        ])
        for row in rows:
            writer.writerow(
                [
                    row.model,
                    row.size_value,
                    row.size_unit,
                    row.params_value,
                    row.params_unit,
                    row.backend,
                    row.d,
                    row.p,
                    row.n,
                    row.pp_mean,
                    row.pp_stddev,
                    row.tg_mean,
                    row.tg_stddev,
                    row.error,
                ]
            )

    print(f"CSV created: {output_csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
