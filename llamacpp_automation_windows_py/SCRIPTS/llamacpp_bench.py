from __future__ import annotations

import os
import re
import subprocess
import tempfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable

from _native import load_config, project_root, resolve_path


@dataclass
class BenchCommand:
    key: str
    device: str
    backend: str
    build_dir: Path
    exe: Path
    base_args: list[str]
    env_overrides: dict[str, str]


def parse_required_bool(value: object, path: str) -> bool:
    _ = path
    return str(value).strip().lower() == "true"


def validate_run_matrix(cfg: dict) -> dict:
    run_matrix = cfg.get("run_matrix")
    if not isinstance(run_matrix, dict):
        raise RuntimeError("run_matrix section is required and must be a mapping")
    for sec in ["devices", "cpu", "gpu", "npu"]:
        if sec not in run_matrix:
            run_matrix[sec] = {}
        elif not isinstance(run_matrix[sec], dict):
            raise RuntimeError(f"run_matrix.{sec} must be a mapping")
    return run_matrix


def parse_int_csv(value: object, field: str) -> str:
    text = str(value).strip()
    if not text:
        raise RuntimeError(f"Missing required value: llamacpp.bench.{field}")
    if not re.fullmatch(r"\d+(\s*,\s*\d+)*", text):
        raise RuntimeError(f"Invalid integer/int-list for llamacpp.bench.{field}: {text}")
    return text


def resolve_ov_runtime_root(configured_root: Path) -> Path | None:
    if (configured_root / "setupvars.bat").is_file():
        return configured_root
    if not configured_root.is_dir():
        return None
    hits = sorted(configured_root.rglob("setupvars.bat"))
    return hits[-1].parent if hits else None


def import_env_from_setupvars_bat(setupvars_bat: Path, env: dict[str, str]) -> None:
    wrapper_path = Path(tempfile.gettempdir()) / "llamacpp_import_openvino_env.cmd"
    wrapper_path.write_text(
        "\n".join(
            [
                "@echo off",
                f'call "{setupvars_bat}" intel64 >nul 2>&1',
                f'if errorlevel 1 call "{setupvars_bat}" >nul 2>&1',
                "set",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    try:
        proc = subprocess.run(["cmd.exe", "/d", "/c", str(wrapper_path)], capture_output=True, text=True, env=env)
        out = (proc.stdout or "").strip()

        imported = 0
        for line in out.splitlines():
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k):
                continue
            env[k] = v
            imported += 1

        # setupvars succeeded only if we imported env and got OpenVINO-related markers.
        has_ov_markers = bool(env.get("INTEL_OPENVINO_DIR") or env.get("OPENVINO_LIB_PATHS"))
        if imported == 0 or not has_ov_markers:
            err = (proc.stderr or "").strip()
            raise RuntimeError(
                f"Failed to import OpenVINO setupvars: {setupvars_bat}. "
                f"rc={proc.returncode}; imported={imported}; stderr={err[:300]}"
            )
    finally:
        if wrapper_path.exists():
            wrapper_path.unlink(missing_ok=True)


def extract_semver(text: str) -> str:
    m = re.search(r"([0-9]+\.[0-9]+\.[0-9]+)", text)
    return m.group(1) if m else ""


def detect_installed_ov_version(ov_runtime_root: Path) -> str:
    vf = ov_runtime_root / "runtime" / "version.txt"
    if not vf.is_file():
        return "N/A"
    first = vf.read_text(encoding="utf-8", errors="ignore").splitlines()
    line = first[0].strip() if first else ""
    sem = extract_semver(line)
    return sem or (line or "N/A")


def resolve_bench_exe(build_dir: Path) -> Path:
    p0 = build_dir / "bin" / "Release" / "llama-bench.exe"
    if p0.is_file():
        return p0
    p1 = build_dir / "llama-bench.exe"
    if p1.is_file():
        return p1
    p2 = build_dir / "bin" / "llama-bench.exe"
    if p2.is_file():
        return p2
    p3 = build_dir / "llama-bench"
    if p3.is_file():
        return p3
    return build_dir / "bin" / "llama-bench"


def resolve_llamacpp_build_root(root: Path, cfg: dict, use_mode: str) -> Path:
    base_build = resolve_path(root, cfg.get("build_dir"), "./BUILD")

    if use_mode == "build":
        modern = base_build / "llamacpp"
        if modern.is_dir():
            return modern
        legacy = base_build / "llama.cpp" / "build"
        return legacy

    # release mode keeps historical release layout if present.
    legacy_release = base_build / "llama.cpp" / "release"
    if legacy_release.is_dir():
        return legacy_release
    return base_build / "llamacpp_release"


def collect_models(root: Path, cfg: dict) -> list[Path]:
    gguf_dir = resolve_path(root, cfg.get("gguf_dir"), "./MODELS/gguf")
    quantizations = (cfg.get("llamacpp", {}) or {}).get("quantizations", []) or []
    if not quantizations:
        raise RuntimeError("Missing llamacpp.quantizations in config.yaml")

    model_paths: dict[str, Path] = {}
    gguf_models = cfg.get("gguf_models", {}) or {}

    for quant in quantizations:
        q = str(quant).strip()
        if not q:
            continue
        qdir = gguf_dir / q
        if not qdir.is_dir():
            print(f"Warning: Missing quantization folder: {qdir}")
            continue

        entries = gguf_models.get(q, []) or []
        if not entries:
            print(f"Warning: No models listed under gguf_models.{q}")
            continue

        for entry in entries:
            raw = str(entry).strip()
            if not raw:
                continue
            if raw.startswith("http://") or raw.startswith("https://"):
                name = raw.split("/")[-1].split("?")[0]
                p = qdir / name
            else:
                p0 = Path(raw)
                if p0.is_absolute():
                    p = p0
                else:
                    p = qdir / p0.name
            if p.is_file():
                model_paths[str(p)] = p
            else:
                print(f"Warning: Config-listed model not found: {p}")

    models = sorted(model_paths.values(), key=lambda p: p.name.lower())
    if not models:
        raise RuntimeError(f"No matching model files found under {gguf_dir}")
    return models


def runtime_env_prefix_map(cfg: dict) -> dict[str, dict[str, str]]:
    rt = ((cfg.get("llamacpp", {}) or {}).get("runtime_env", {}) or {})
    out: dict[str, dict[str, str]] = {}
    for d in ("cpu", "gpu", "npu"):
        env_block = rt.get(d, {}) or {}
        valid: dict[str, str] = {}
        for k, v in env_block.items():
            ks = str(k).strip()
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", ks):
                valid[ks] = str(v)
        out[d.upper()] = valid
    return out


def enabled_devices(run_matrix: dict) -> list[str]:
    dev = run_matrix["devices"]
    out: list[str] = []
    if parse_required_bool(dev.get("cpu", False), "run_matrix.devices.cpu"):
        out.append("CPU")
    if parse_required_bool(dev.get("gpu", False), "run_matrix.devices.gpu"):
        out.append("GPU")
    if parse_required_bool(dev.get("npu", False), "run_matrix.devices.npu"):
        out.append("NPU")
    return out


def select_backends(run_matrix: dict, device: str) -> list[str]:
    if device == "CPU":
        b = []
        cpu = run_matrix["cpu"]
        if parse_required_bool(cpu.get("llamacpp_ggml_cpu", False), "run_matrix.cpu.llamacpp_ggml_cpu"):
            b.append("llamacpp_barecpu")
        if parse_required_bool(cpu.get("llamacpp_ov_cpu", False), "run_matrix.cpu.llamacpp_ov_cpu"):
            b.append("llamacpp_openvino")
        return b
    if device == "GPU":
        b = []
        gpu = run_matrix["gpu"]
        if parse_required_bool(gpu.get("llamacpp_vulkan_gpu", False), "run_matrix.gpu.llamacpp_vulkan_gpu"):
            b.append("llamacpp_vulkan")
        if parse_required_bool(gpu.get("llamacpp_ov_gpu", False), "run_matrix.gpu.llamacpp_ov_gpu"):
            b.append("llamacpp_openvino")
        return b
    if device == "NPU":
        npu = run_matrix["npu"]
        return ["llamacpp_openvino"] if parse_required_bool(npu.get("llamacpp_ov_npu", False), "run_matrix.npu.llamacpp_ov_npu") else []
    return []


def build_commands(root: Path, cfg: dict) -> list[BenchCommand]:
    run_matrix = validate_run_matrix(cfg)
    run_devices = enabled_devices(run_matrix)
    if not run_devices:
        raise RuntimeError("No enabled devices found in run_matrix.devices")

    llm = cfg.get("llamacpp", {}) or {}
    bench = llm.get("bench", {}) or {}
    reps = parse_int_csv(bench.get("repetitions", ""), "repetitions")
    pp = parse_int_csv(bench.get("pp_tokens", ""), "pp_tokens")
    tg = parse_int_csv(bench.get("tg_tokens", ""), "tg_tokens")
    npu_pp = parse_int_csv(bench.get("npu_pp_tokens", ""), "npu_pp_tokens")
    npu_tg = parse_int_csv(bench.get("npu_tg_tokens", ""), "npu_tg_tokens")
    gpu_depth = parse_int_csv(bench.get("gpu_depth", ""), "gpu_depth")
    ngl = parse_int_csv(bench.get("n_gpu_layers", ""), "n_gpu_layers")

    use_mode = str(llm.get("use", "build")).strip().lower()
    if use_mode not in {"build", "release"}:
        raise RuntimeError("llamacpp.use must be build or release")

    build_root = resolve_llamacpp_build_root(root, cfg, use_mode)
    env_map = runtime_env_prefix_map(cfg)
    cmd_map: dict[str, BenchCommand] = {}

    for device in ("CPU", "GPU", "NPU"):
        if device not in run_devices:
            continue
        backends = select_backends(run_matrix, device)
        if not backends:
            raise RuntimeError(f"No backend enabled for {device} in run_matrix")

        for backend in backends:
            env = dict(env_map.get(device, {}))
            args: list[str]
            bdir: Path

            if device == "CPU" and backend == "llamacpp_barecpu":
                bdir = build_root / "Release"
                args = ["-r", reps, "-p", pp, "-n", tg]
            elif device == "CPU" and backend == "llamacpp_openvino":
                bdir = build_root / "ReleaseOV"
                if not env:
                    env = {"GGML_OPENVINO_DEVICE": "CPU", "GGML_OPENVINO_STATEFUL_EXECUTION": "1"}
                args = ["-fa", "1", "-r", reps, "-p", pp, "-n", tg]
            elif device == "GPU" and backend == "llamacpp_vulkan":
                bdir = build_root / "ReleaseVulkan"
                args = ["-r", reps, "-d", gpu_depth, "-ngl", ngl, "-p", pp, "-n", tg]
            elif device == "GPU" and backend == "llamacpp_openvino":
                bdir = build_root / "ReleaseOV"
                if not env:
                    env = {"GGML_OPENVINO_DEVICE": "GPU", "GGML_OPENVINO_STATEFUL_EXECUTION": "1"}
                args = ["-fa", "1", "-r", reps, "-d", gpu_depth, "-ngl", ngl, "-p", pp, "-n", tg]
            elif device == "NPU" and backend == "llamacpp_openvino":
                bdir = build_root / "ReleaseOV"
                if not env:
                    env = {"GGML_OPENVINO_DEVICE": "NPU"}
                args = ["-fa", "1", "-r", reps, "-p", npu_pp, "-n", npu_tg]
            else:
                continue

            exe = resolve_bench_exe(bdir)
            if not exe.is_file():
                print(f"Warning: skipping {device}/{backend}; binary not found: {exe}")
                continue

            key = f"{device}:{backend}"
            if key not in cmd_map:
                cmd_map[key] = BenchCommand(key, device, backend, bdir, exe, args, env)

    if not cmd_map:
        raise RuntimeError("No runnable llama benchmark backends selected")

    return list(cmd_map.values())


def ov_precheck_and_import(root: Path, cfg: dict, env: dict[str, str], commands: Iterable[BenchCommand]) -> None:
    needs_ov = any("ReleaseOV" in str(c.build_dir) for c in commands)
    if not needs_ov:
        return

    llm = cfg.get("llamacpp", {}) or {}
    use_mode = str(llm.get("use", "build")).strip().lower()
    logs_dir = resolve_path(root, cfg.get("logs_dir"), "./logs")
    ov_log = logs_dir / f"ov_build_info_{use_mode}.txt"

    if use_mode == "build":
        dep_root = resolve_path(root, cfg.get("dependency_dir"), "./DEPENDENCIES")
        ov_root = dep_root / "openvino"
    else:
        build_root = resolve_llamacpp_build_root(root, cfg, use_mode)
        ov_root = build_root / "OpenVINO_release_runtime"

    ov_runtime = resolve_ov_runtime_root(ov_root)
    if ov_runtime is None:
        raise RuntimeError(f"OpenVINO setupvars.bat not found under {ov_root}")

    setupvars = ov_runtime / "setupvars.bat"
    if not setupvars.is_file():
        raise RuntimeError(f"Missing OpenVINO setupvars.bat: {setupvars}")

    installed = detect_installed_ov_version(ov_runtime)
    if use_mode == "build":
        if not ov_log.is_file():
            raise RuntimeError(f"Missing OpenVINO build log: {ov_log}. Run llamacpp_build.py")
        logged_raw = ov_log.read_text(encoding="utf-8", errors="ignore").splitlines()
        logged = extract_semver(logged_raw[0] if logged_raw else "")
        if not logged:
            raise RuntimeError(f"Invalid OpenVINO build log format: {ov_log}")
        if installed == "N/A":
            raise RuntimeError(f"Could not detect installed OpenVINO version at {ov_runtime}")
        if installed != logged:
            raise RuntimeError(
                f"OpenVINO version mismatch: logged={logged}, installed={installed}. Rebuild ReleaseOV with llamacpp_build.py"
            )

    dll_dir = ov_runtime / "runtime" / "bin"
    if not dll_dir.is_dir() or not any(dll_dir.rglob("openvino*.dll")):
        raise RuntimeError(f"OpenVINO runtime DLLs not found under {dll_dir}")

    import_env_from_setupvars_bat(setupvars, env)


def format_exec_line(cmd: BenchCommand) -> str:
    env_part = " ".join(f"{k}={v}" for k, v in cmd.env_overrides.items())
    core = " ".join([str(cmd.exe), *cmd.base_args])
    return f"{env_part} {core}".strip()


def main() -> int:
    root = project_root(__file__)
    cfg = load_config(root)
    env = dict(os.environ)

    models = collect_models(root, cfg)
    commands = build_commands(root, cfg)
    ov_precheck_and_import(root, cfg, env, commands)

    results_dir = resolve_path(root, cfg.get("results_dir"), "./RESULTS")
    results_dir.mkdir(parents=True, exist_ok=True)
    out = results_dir / f"llamabench_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"

    print(f"Found {len(models)} selected models")
    print(f"Saving all run outputs to: {out}")

    with out.open("w", encoding="utf-8") as fh:
        for cmd in commands:
            for model in models:
                run_env = dict(env)
                run_env.update(cmd.env_overrides)
                full_cmd = [str(cmd.exe), *cmd.base_args, "-m", str(model)]
                exec_line = f"{format_exec_line(cmd)} -m {model}"

                fh.write("------------------------------------------------\n")
                fh.write(f">> Executing: {exec_line}\n")
                fh.write(">>\n")
                fh.write(f">> Model: {model.name}\n")
                fh.write(">>\n")
                fh.write(f">> Output File: {out}\n")

                proc = subprocess.run(full_cmd, env=run_env, capture_output=True, text=True)
                merged = (proc.stdout or "") + (proc.stderr or "")
                merged = "\n".join(line for line in merged.splitlines() if not line.startswith("load_backend:"))
                if merged:
                    fh.write(merged)
                    if not merged.endswith("\n"):
                        fh.write("\n")

                if proc.returncode != 0:
                    fh.write(f"Warning: Command failed (exit={proc.returncode}) for model {model.name}. Continuing.\n")

                fh.write("------------------------------------------------\n")

    print(f"Benchmark completed: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
