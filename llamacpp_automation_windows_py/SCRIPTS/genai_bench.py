from __future__ import annotations

import os
from datetime import datetime
from pathlib import Path

from _native import apply_proxy_env_from_config, load_config, project_root, resolve_path, run_cmd


def venv_python(build_dir: Path) -> Path:
    return build_dir / "openvino.genai" / "tools" / "llm_bench" / "python-env" / "Scripts" / "python.exe"


def main() -> int:
    root = project_root(__file__)
    cfg = load_config(root)
    env = dict(os.environ)
    apply_proxy_env_from_config(cfg, env)

    build_dir = resolve_path(root, cfg.get("build_dir"), "./BUILD")
    ir_dir = resolve_path(root, cfg.get("ir_dir"), "./MODELS/ir")
    results_dir = resolve_path(root, cfg.get("results_dir"), "./RESULTS")
    results_dir.mkdir(parents=True, exist_ok=True)

    bench_cfg = cfg.get("genai", {}).get("benchmark", {}) or {}
    ic = str(bench_cfg.get("initial_content_length", 128))
    iters = str(bench_cfg.get("iterations", 1))
    prompt = str(bench_cfg.get("prompt", "")).strip()
    prompt_file = str(bench_cfg.get("prompt_file", "")).strip()
    mc = str(bench_cfg.get("max_context", 1))

    py = venv_python(build_dir)
    bench_script = build_dir / "openvino.genai" / "tools" / "llm_bench" / "benchmark.py"
    if not py.is_file() or not bench_script.is_file():
        raise RuntimeError("GenAI benchmark prerequisites missing. Run genai_build.py first.")

    out = results_dir / f"genaibench_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"

    models = cfg.get("ir_models", {}).get("models", []) or []
    run_matrix = cfg.get("run_matrix", {}) or {}
    dev_flags = (run_matrix.get("devices") or {})
    run_matrix_gpu_raw = dev_flags.get("gpu")
    run_matrix_npu_raw = dev_flags.get("npu")

    selected_devices: list[str] = []
    if run_matrix_gpu_raw is not None or run_matrix_npu_raw is not None:
        if str(run_matrix_gpu_raw).lower() == "true":
            if str((run_matrix.get("gpu") or {}).get("ov_genai_ir_gpu", "false")).lower() == "true":
                selected_devices.append("GPU")
            else:
                print("Warning: run_matrix.devices.gpu=true but run_matrix.gpu.ov_genai_ir_gpu=false; skipping GPU")
        if str(run_matrix_npu_raw).lower() == "true":
            if str((run_matrix.get("npu") or {}).get("ov_genai_ir_npu", "false")).lower() == "true":
                selected_devices.append("NPU")
            else:
                print("Warning: run_matrix.devices.npu=true but run_matrix.npu.ov_genai_ir_npu=false; skipping NPU")
    else:
        defaults_devices = (cfg.get("defaults") or {}).get("devices") or []
        for dev in defaults_devices:
            norm = str(dev).strip().upper()
            if norm in {"GPU", "NPU"} and norm not in selected_devices:
                selected_devices.append(norm)

    if not selected_devices:
        raise RuntimeError(
            "No supported GenAI devices selected. Configure run_matrix or defaults.devices with GPU/NPU."
        )

    prompt_args: list[str]
    if prompt:
        prompt_args = ["-p", prompt]
    elif prompt_file:
        pf = Path(prompt_file)
        if not pf.is_absolute():
            pf = (root / prompt_file).resolve()
        if not pf.is_file():
            raise RuntimeError(f"Configured prompt_file does not exist: {pf}")
        prompt_args = ["-pf", str(pf)]
    else:
        raise RuntimeError("Configure genai.benchmark.prompt or prompt_file")

    total = 0
    with out.open("w", encoding="utf-8") as fh:
        for device in selected_devices:
            for model in models:
                m = str(model).strip()
                if not m:
                    continue
                name = m.split("/", 1)[-1].replace("/", "__")
                model_dir = ir_dir / device / name
                model_xml = model_dir / "openvino_model.xml"
                if not model_xml.is_file():
                    continue
                cmd = [
                    str(py),
                    str(bench_script),
                    "-ic",
                    ic,
                    "-n",
                    iters,
                    *prompt_args,
                    "-d",
                    device,
                    "-mc",
                    mc,
                    "-m",
                    str(model_dir),
                ]
                fh.write("------------------------------------------------\n")
                fh.write(f">> Device: {device}\n")
                fh.write(f">> Model Dir: {model_dir}\n")
                fh.flush()
                proc = run_cmd(cmd, cwd=root, env=env, check=False, capture_output=True)
                fh.write(proc.stdout or "")
                fh.write(proc.stderr or "")
                fh.write("\n")
                fh.flush()
                if proc.returncode != 0:
                    raise RuntimeError(f"GenAI benchmark failed for {device}/{m}")
                total += 1

    if total == 0:
        raise RuntimeError("No GenAI benchmark runs executed (no exported IR models found)")

    print(f"Completed {total} GenAI runs -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
