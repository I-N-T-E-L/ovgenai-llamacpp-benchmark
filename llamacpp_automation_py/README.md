# llama.cpp + OpenVINO Automation (Unified Workflow)

Automated, cross-platform benchmarking pipeline for:
- llama.cpp backends: CPU (GGML), Vulkan GPU, OpenVINO (CPU/GPU/NPU)
- OpenVINO GenAI benchmark: exported IR models on GPU/NPU

The repository provides a single unified runner that builds dependencies, downloads models, runs benchmarks, parses outputs, and emits CSV summaries.

## What This Repo Does

1. Builds or fetches llama.cpp artifacts (depending on mode/platform).
2. Downloads GGUF models from config-defined URLs.
3. Runs llama-bench across enabled devices/backends.
4. Parses llama-bench logs to CSV with system metadata.
5. Prepares OpenVINO GenAI Python environment.
6. Exports Hugging Face models to OpenVINO IR for GPU/NPU.
7. Runs GenAI benchmark.
8. Parses GenAI logs to CSV.
9. Produces a unified result CSV in project root.

## Repository Layout

- `run_llamabench_unified.py`: end-to-end orchestrator and preflight checker.
- `config.yaml`: main configuration (run matrix, model lists, build/output paths, OpenVINO URLs).
- `SCRIPTS/`: all step scripts and shared helpers.
  - `_linux_common.py`, `_windows_common_.py`: shared utilities per OS.
  - `llamacpp_build.py`: llama.cpp setup/build.
  - `gguf_downloader.py`: GGUF model download.
  - `llamacpp_bench.py`: llama-bench execution.
  - `llamacpp_parser.py`: llama-bench text to CSV.
  - `genai_build.py`: openvino.genai environment setup.
  - `ovir_downloader.py`: HF model export to OpenVINO IR.
  - `genai_bench.py`: GenAI benchmark execution.
  - `genai_parser.py`: GenAI text to CSV.
  - `sys_config.py`: hardware/system info report injected into CSV headers.

## Key Design Notes

- Scripts are wrapper entrypoints that dispatch to embedded Linux/Windows implementations.
- The unified runner performs wrapper syntax compilation before actual execution to fail fast on escaping/syntax mistakes.
- Model and device selection is configuration-driven via `config.yaml`.
- Existing artifacts are reused when `auto_update: false`; update/rebuild behavior is enabled when `auto_update: true`.
- For config path values, use forward slashes on both Linux and Windows (example: `C:/VulkanSDK/...`); backslashes can work but are more error-prone in YAML/env parsing contexts.

## Prerequisites

## Windows

- Python 3.10+.
- Visual Studio Build Tools with C++ toolchain.
- Vulkan SDK installed (if Vulkan backend enabled).
- Internet access to GitHub, Hugging Face, OpenVINO storage.

Download links:
- Visual Studio Build Tools (installer): https://aka.ms/vs/17/release/vs_BuildTools.exe
- Vulkan SDK for Windows: https://vulkan.lunarg.com/sdk/home#windows

After installing, update `config.yaml` in this repository (under the `llamacpp:` section):

- If you installed Visual Studio Build Tools, set the `msvc_env_bat_path` value to your local `VsDevCmd.bat` path.
- If you installed Vulkan SDK and Vulkan runs are enabled, set `vulkan_sdk_path` to your local Vulkan SDK root folder.

Example `config.yaml` edit:

```yaml
llamacpp:
  msvc_env_bat_path: "C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/Common7/Tools/VsDevCmd.bat"
  vulkan_sdk_path: "C:/VulkanSDK/1.4.350.0"
```

## Linux

- Python 3.10+.
- Ubuntu/Debian-like environment with `apt-get` (for automatic dependency install in build step).
- Internet access to GitHub, Hugging Face, OpenVINO storage.

## Setup

1. Clone repository.
2. Edit `config.yaml`:
   - Set directories.
   - Set run matrix toggles.
   - Select models.
   - Configure proxy if needed.
3. Run preflight check:

```bash
python run_llamabench_unified.py --check
```

If preflight succeeds, run full workflow:

```bash
python run_llamabench_unified.py
```

## Configuration Guide (config.yaml)

## 1) Proxy

```yaml
proxy:
  use_proxy: true
  proxy_list:
    - HTTP_PROXY=http://proxy:port
    - HTTPS_PROXY=http://proxy:port
    - NO_PROXY=localhost,127.0.0.1
```

- Applied by downloader/build/export scripts.
- Proxy is optional and should be enabled only when needed.
- Windows downloader includes proxy/direct fallback logic for Hugging Face hosts.

## 2) Auto-update

```yaml
auto_update: false
```

- `false`: reuse existing assets when present.
- `true`: refresh source/runtime and trigger rebuild logic as needed.
- Practical note: first run mainly bootstraps artifacts and commit/version logs; update-vs-reuse decisions become meaningful from second run onward.
- When enabled, it governs whether newer llama.cpp/OpenVINO/openvino.genai state should be fetched and whether related rebuild/setup should be triggered.

## 3) Run matrix

```yaml
run_matrix:
  devices:
    cpu: true
    gpu: true
    npu: true
```

And per-device backend toggles:
- CPU: `llamacpp_ggml_cpu`, `llamacpp_ov_cpu`, `ov_genai_ir_cpu`
- GPU: `llamacpp_vulkan_gpu`, `llamacpp_ov_gpu`, `ov_genai_ir_gpu`
- NPU: `llamacpp_ov_npu`, `ov_genai_ir_npu`
- Hierarchy rule: `run_matrix.devices` is the top-level gate. If a device is disabled there, its individual backend flags are ignored.

## 4) OpenVINO package URLs

```yaml
openvino:
  version: default   # default | latest
  linux_default_url: ...
  windows_default_url: ...
```

- With `version: default`, scripts use `openvino.linux_default_url` on Linux and `openvino.windows_default_url` on Windows.
- With `version: latest`, scripts resolve the latest OS-appropriate OpenVINO package by querying OpenVINO filetree metadata online.

## 5) llama.cpp mode

```yaml
llamacpp:
  use: build   # build | release
```

- Linux: supports both `build` and `release`.
- Windows native flow: `build` only.
- Recommendation: use `build` mode for now. `release` path is still less stable/portable (especially around OpenVINO package/runtime compatibility).
- `llamacpp.perplexity` and `llamacpp.cli_smoke` config blocks are currently in development and not active in this workflow.

## 6) Model lists

- `gguf_models`: URL lists grouped by quantization (`Q4_0`, `Q4_K_M`, etc).
- `ir_models.models`: Hugging Face model IDs for IR export.
- `ir_models.params.gpu/npu`: export quantization flags.
- `genai.benchmark.prompt` takes precedence over `genai.benchmark.prompt_file` when both are provided.
- Commented (`#`) GGUF entries are not loaded from YAML, so they are not downloaded and are not selected for benchmark runs (even if similarly named files exist locally).
- `ir_models.params` controls per-device export quantization behavior; each entry in `ir_models.models` is processed for both GPU and NPU export variants (subject to per-device export success).

## Script-by-Script Utility

- `llamacpp_build.py`
  - Linux: installs dependencies, manages OpenVINO runtime, builds or downloads backend artifacts.
  - Windows: prepares tools (git/cmake/ninja/w64devkit), configures MSVC and Vulkan, builds Release/ReleaseVulkan/ReleaseOV with rebuild plan logic.

- `gguf_downloader.py`
  - Downloads configured GGUF models into quantization folders.
  - Skips existing files.

- `llamacpp_bench.py`
  - Builds benchmark command matrix from run_matrix.
  - Runs per model and backend.
  - Writes timestamped text logs and prints captured benchmark output.

- `llamacpp_parser.py`
  - Converts latest `llamabench_*.txt` to CSV.
  - Adds system metadata (`sys_config.py`), commit/version info, and missing-GGUF report.

- `genai_build.py`
  - Clones `openvino.genai` and prepares `tools/llm_bench/python-env`.
  - Installs requirements + pinned versions (`transformers==4.55.4`, `diffusers<0.35`).

- `ovir_downloader.py`
  - Exports configured HF models to OpenVINO IR for GPU/NPU.
  - Handles optional HF token from config.
  - Includes retry path that temporarily adjusts transformers version if export demands compatibility.

- `genai_bench.py`
  - Runs `openvino.genai/tools/llm_bench/benchmark.py` for selected devices/models.
  - Emits `genaibench_*.txt`.

- `genai_parser.py`
  - Converts GenAI benchmark log to CSV.
  - Adds missing-HF-model report header.

## Outputs

- Text logs:
  - `RESULTS/llamabench_YYYYmmdd_HHMMSS.txt`
  - `RESULTS/genaibench_YYYYmmdd_HHMMSS.txt`

- CSV outputs:
  - `RESULTS/llamabench_*.csv`
  - `RESULTS/genaibench_*.csv`

- Unified CSV in repo root:
  - `result_YYYYmmdd_HHMMSS.csv`

- Build/runtime logs (commit/version tracking):
  - `logs/llama_cpp_commit_<mode>.txt`
  - `logs/ov_build_info_<mode>.txt`
  - `logs/openvino_genai_commit_<mode>.txt`

## Health Check and Validation

Run only validation:

```bash
python run_llamabench_unified.py --check
```

This validates:
- config presence and required paths
- workflow scripts presence
- wrapper script syntax compilation

## Common Issues and Troubleshooting

## 1) Proxy/Hugging Face download failures

Symptoms:
- connection reset/proxy errors while downloading GGUF or HF artifacts.

Actions:
- Verify `proxy.use_proxy` and `proxy.proxy_list` values.
- Ensure corporate proxy allows Hugging Face and GitHub hosts.
- On Windows, the downloader already retries with direct connection for HF-like hosts.

## 2) Parser or wrapper syntax errors

Actions:
- Run `python run_llamabench_unified.py --check` first.
- Fix escaping/syntax in wrapper script files under `SCRIPTS/`.

## 3) Missing GenAI environment

Symptom:
- `optimum-cli` or GenAI benchmark script not found.

Action:
- Run `SCRIPTS/genai_build.py` before export/benchmark steps.

## Example Workflow

```bash
python run_llamabench_unified.py --check
python run_llamabench_unified.py
```

Then inspect:
- latest files in `RESULTS/`
- unified `result_*.csv` in repo root

## Notes for Contributors

- Keep Linux/Windows behavior aligned when adding features.
- Validate wrapper scripts compile after edits.
- Prefer config-driven toggles over hardcoded model/device values.
- If changing output format, update corresponding parser script.
