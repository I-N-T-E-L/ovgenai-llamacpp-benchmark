from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from _native import apply_proxy_env_from_config, load_config, project_root, resolve_path


def is_true(v: object) -> bool:
    return str(v).strip().lower() in {"1", "true", "yes"}


def venv_python(build_dir: Path) -> Path:
    venv = build_dir / "openvino.genai" / "tools" / "llm_bench" / "python-env"
    p = venv / "Scripts" / "python.exe"
    if p.is_file():
        return p
    p2 = venv / "bin" / "python"
    return p2


def run_capture(cmd: list[str], env: dict[str, str], cwd: Path) -> tuple[int, str]:
    p = subprocess.run(cmd, cwd=str(cwd), env=env, capture_output=True, text=True)
    out = (p.stdout or "") + (p.stderr or "")
    if out:
        print(out, end="" if out.endswith("\n") else "\n")
    return p.returncode, out


def get_transformers_version(py: Path, env: dict[str, str], cwd: Path) -> str:
    code = "import transformers; print(transformers.__version__)"
    p = subprocess.run([str(py), "-c", code], cwd=str(cwd), env=env, capture_output=True, text=True)
    return (p.stdout or "").strip() if p.returncode == 0 else ""


def install_transformers(py: Path, env: dict[str, str], cwd: Path, version: str) -> bool:
    if not version:
        return False
    cmd = [str(py), "-m", "pip", "install", "-q", f"transformers=={version}"]
    return subprocess.run(cmd, cwd=str(cwd), env=env).returncode == 0


def uninstall_transformers(py: Path, env: dict[str, str], cwd: Path) -> None:
    subprocess.run([str(py), "-m", "pip", "uninstall", "-y", "transformers"], cwd=str(cwd), env=env, capture_output=True, text=True)


def extract_failure_reason(output: str) -> str:
    patterns = [
        r"Maximum required is.*",
        r"not supported.*",
        r"unsupported.*",
        r"Unknown model type.*",
        r"requires\s+transformers.*",
        r"ValueError.*",
        r"RuntimeError.*",
        r"OSError.*",
        r"Exception.*",
        r"Traceback.*",
    ]
    lines = [ln.strip() for ln in output.splitlines() if ln.strip()]
    for pat in patterns:
        m = [ln for ln in lines if re.search(pat, ln, flags=re.IGNORECASE)]
        if m:
            return m[-1]
    return lines[-1] if lines else "Unknown export failure (empty log output)"


def extract_transformers_target_version(output: str) -> str:
    m = re.search(r"Maximum required is\s+([0-9]+\.[0-9]+\.[0-9]+)", output)
    if m:
        return m.group(1)
    m = re.search(r"requires\s+transformers[^0-9]*([0-9]+\.[0-9]+\.[0-9]+)", output, flags=re.IGNORECASE)
    if m:
        return m.group(1)
    m = re.search(r"transformers==([0-9]+\.[0-9]+\.[0-9]+)", output)
    return m.group(1) if m else ""


def optimum_export_cmd(py: Path, model: str, out_dir: Path, params: dict) -> list[str]:
    cmd = [
        str(py),
        "-m",
        "optimum.commands.optimum_cli",
        "export",
        "openvino",
        "-m",
        model,
    ]

    wf = str(params.get("weight_format", "") or "").strip()
    if wf:
        cmd += ["--weight-format", wf]

    if is_true(params.get("sym", False)):
        cmd += ["--sym"]

    ratio = params.get("ratio")
    if str(ratio).strip() not in {"", "None"}:
        cmd += ["--ratio", str(ratio)]

    gs = params.get("group_size")
    if str(gs).strip() not in {"", "None"}:
        cmd += ["--group-size", str(gs)]

    if is_true(params.get("trust_remote_code", False)):
        cmd += ["--trust-remote-code"]

    cmd += [str(out_dir)]
    return cmd


def export_with_optional_transformers_retry(
    py: Path,
    model: str,
    device: str,
    hf_root: Path,
    params: dict,
    env: dict[str, str],
    cwd: Path,
    initial_tf: str,
) -> tuple[Path | None, str | None]:
    tmp = Path(tempfile.mkdtemp(prefix=f".{device.lower()}_", dir=str(hf_root)))
    rc, out = run_capture(optimum_export_cmd(py, model, tmp, params), env, cwd)
    if rc == 0:
        return tmp, None

    combined = out
    target = extract_transformers_target_version(combined)
    changed_tf = False

    if target:
        print(f"Info: {device} export for {model} suggests transformers=={target}. Retrying with that version")
        current = get_transformers_version(py, env, cwd)
        changed_tf = current != target

        if install_transformers(py, env, cwd, target):
            shutil.rmtree(tmp, ignore_errors=True)
            tmp = Path(tempfile.mkdtemp(prefix=f".{device.lower()}_retry_", dir=str(hf_root)))
            rc2, out2 = run_capture(optimum_export_cmd(py, model, tmp, params), env, cwd)
            if rc2 == 0:
                if changed_tf:
                    if initial_tf:
                        print(f"Info: Restoring transformers=={initial_tf}")
                        install_transformers(py, env, cwd, initial_tf)
                    else:
                        print("Info: Restoring environment by removing transformers")
                        uninstall_transformers(py, env, cwd)
                return tmp, None
            combined = (combined + "\n" + out2).strip()
        else:
            print(f"Warning: Failed to install transformers=={target} for retry.")

    if changed_tf:
        if initial_tf:
            print(f"Info: Restoring transformers=={initial_tf}")
            install_transformers(py, env, cwd, initial_tf)
        else:
            print("Info: Restoring environment by removing transformers")
            uninstall_transformers(py, env, cwd)

    reason = extract_failure_reason(combined)
    shutil.rmtree(tmp, ignore_errors=True)
    return None, reason


def main() -> int:
    root = project_root(__file__)
    cfg = load_config(root)
    env = dict(os.environ)
    apply_proxy_env_from_config(cfg, env)

    hf_token = str(((cfg.get("ir_models", {}) or {}).get("hf_token", "") or "")).strip()
    if hf_token:
        env["HF_TOKEN"] = hf_token
        env["HUGGINGFACE_HUB_TOKEN"] = hf_token
        env["HF_HUB_TOKEN"] = hf_token
        print("Applied optional hf_token from config.yaml")

    build_dir = resolve_path(root, cfg.get("build_dir"), "./BUILD")
    hf_root = resolve_path(root, cfg.get("ir_dir"), "./MODELS/ir")
    hf_root.mkdir(parents=True, exist_ok=True)
    print(f"IR models root set to: {hf_root}")

    py = venv_python(build_dir)
    if not py.is_file():
        raise RuntimeError("GenAI Python environment missing. Run genai_build.py first.")

    chk = subprocess.run([str(py), "-m", "optimum.commands.optimum_cli", "--help"], capture_output=True, text=True, env=env)
    if chk.returncode != 0:
        raise RuntimeError("optimum-cli not found in GenAI environment")

    ir_models = cfg.get("ir_models", {}) or {}
    models = [str(m).strip() for m in (ir_models.get("models", []) or []) if str(m).strip()]
    if not models:
        raise RuntimeError("No models found in ir_models.models")

    params = ir_models.get("params", {}) or {}
    gpu_params = params.get("gpu", {}) or {}
    npu_params = params.get("npu", {}) or {}

    initial_tf = get_transformers_version(py, env, root)
    if initial_tf:
        print(f"Detected transformers version: {initial_tf}")
    else:
        print("Warning: transformers is not currently installed in the active environment.")

    success_count = 0
    fail_count = 0
    failures: list[str] = []
    status_items: list[str] = []

    for model in models:
        print("\n============================================================")
        print(f"Model: {model}")
        print("============================================================")

        stripped = model.split("/", 1)[-1]
        safe_name = stripped.replace("/", "__")

        for device, pset in (("NPU", npu_params), ("GPU", gpu_params)):
            out_dir = hf_root / device / safe_name
            if (out_dir / "openvino_model.xml").is_file():
                print(f"Skipping {device} export for {model} (already exists at {out_dir})")
                success_count += 1
                status_items.append(f"{device}|{model}|QUANTIZED")
                continue

            print(f"Exporting {device} model: {model} -> {out_dir}")
            tmp, reason = export_with_optional_transformers_retry(py, model, device, hf_root, pset, env, root, initial_tf)

            if tmp and tmp.is_dir():
                out_dir.parent.mkdir(parents=True, exist_ok=True)
                shutil.rmtree(out_dir, ignore_errors=True)
                shutil.move(str(tmp), str(out_dir))
                success_count += 1
                status_items.append(f"{device}|{model}|QUANTIZED")
            else:
                fail_count += 1
                msg = reason or "Unknown export failure"
                print(f"Warning: {device} export failed for {model}")
                print(f"Reason: {msg}")
                failures.append(f"{device}|{model}|{msg}")
                status_items.append(f"{device}|{model}|NOT_QUANTIZED")

    print("\nDevice-wise quantization status:")
    if status_items:
        for item in status_items:
            d, m, s = item.split("|", 2)
            print(f"  - {d} :: {m} :: {s}")
    else:
        print("  - NONE")

    print("\nSummary:")
    print(f"  - successful_exports: {success_count}")
    print(f"  - failed_exports: {fail_count}")

    if failures:
        print("\nFailures:")
        for item in failures:
            d, m, r = item.split("|", 2)
            print(f"  - {d} :: {m} :: {r}")

    print("Process complete.")
    return 0 if fail_count == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
