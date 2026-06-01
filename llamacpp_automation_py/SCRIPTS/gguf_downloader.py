#!/usr/bin/env python3
from __future__ import annotations

import inspect
import platform
import sys
import types
from pathlib import Path


def _run_impl(source: str, impl_name: str) -> int:
    module_name = f'{__name__}.{impl_name}'
    module = types.ModuleType(module_name)
    module.__file__ = str(Path(__file__).resolve())
    sys.modules[module_name] = module
    namespace = module.__dict__
    exec(compile(source, str(Path(__file__).resolve()), 'exec'), namespace, namespace)
    main_fn = namespace.get('main')
    if not callable(main_fn):
        raise RuntimeError(f"Selected implementation '{impl_name}' for 'gguf_downloader' does not define main()")
    sig = inspect.signature(main_fn)
    if len(sig.parameters) == 0:
        return int(main_fn())
    if len(sig.parameters) == 1:
        return int(main_fn(sys.argv))
    raise RuntimeError(f"Selected implementation '{impl_name}' for 'gguf_downloader' has unsupported main() signature")


def main() -> int:
    if platform.system().strip().lower().startswith('win'):
        return _run_impl(_WINDOWS_IMPL, 'windows')
    return _run_impl(_LINUX_IMPL, 'linux')


_LINUX_IMPL = 'from __future__ import annotations\n\nimport os\nfrom pathlib import Path\nfrom urllib.parse import urlparse\n\nfrom _linux_common import CONFIG_FILE, apply_optional_proxy, load_config, resolve_path, run_stream\n\n\ndef _is_url(text: str) -> bool:\n\ttry:\n\t\tparsed = urlparse(text)\n\t\treturn parsed.scheme in {"http", "https"} and bool(parsed.netloc)\n\texcept Exception:\n\t\treturn False\n\n\ndef main() -> int:\n\tif not CONFIG_FILE.is_file():\n\t\tprint(f"Error: {CONFIG_FILE} not found.")\n\t\treturn 1\n\n\tcfg = load_config()\n\tenv = dict(os.environ)\n\tapply_optional_proxy(cfg, env)\n\tif env != os.environ:\n\t\tprint(f"Applied proxy settings from {CONFIG_FILE}")\n\n\tgguf_root_raw = cfg.get("gguf_dir")\n\tif not gguf_root_raw:\n\t\tprint(f"Error: Missing gguf_dir in {CONFIG_FILE}")\n\t\treturn 1\n\n\tgguf_root = resolve_path(str(gguf_root_raw))\n\tgguf_root.mkdir(parents=True, exist_ok=True)\n\tprint(f"GGUF root set to: {gguf_root}")\n\n\tselected_quants = [str(q).strip() for q in (cfg.get("llamacpp", {}).get("quantizations") or []) if str(q).strip()]\n\tif not selected_quants:\n\t\tprint(f"Error: llamacpp.quantizations is empty in {CONFIG_FILE}")\n\t\treturn 1\n\n\tmodels_by_quant = cfg.get("gguf_models") or {}\n\tprint(f"Scanning {CONFIG_FILE} for GGUF URLs from selected quantizations...")\n\n\tfor quant in selected_quants:\n\t\tquant_dir = gguf_root / quant\n\t\tquant_dir.mkdir(parents=True, exist_ok=True)\n\n\t\turls = [str(u).strip() for u in (models_by_quant.get(quant) or []) if str(u).strip()]\n\t\tif not urls:\n\t\t\tprint(f"Warning: No gguf_models.{quant} entry")\n\t\t\tcontinue\n\n\t\tfor url in urls:\n\t\t\tif not _is_url(url):\n\t\t\t\tprint(f"Warning: Skipping non-URL entry under quantization \'{quant}\': {url}")\n\t\t\t\tcontinue\n\n\t\t\tfile_name = Path(urlparse(url).path).name\n\t\t\tif not file_name:\n\t\t\t\tprint(f"Warning: Could not derive filename from URL: {url}")\n\t\t\t\tcontinue\n\n\t\t\tout_file = quant_dir / file_name\n\t\t\tif out_file.is_file():\n\t\t\t\tprint(f"Skipping: {file_name} already exists in {quant_dir}")\n\t\t\t\tcontinue\n\n\t\t\tprint(f"Downloading [{quant}]: {url}")\n\t\t\trc = run_stream(["wget", "-q", "--show-progress", "-P", str(quant_dir), url], env=env)\n\t\t\tif rc != 0:\n\t\t\t\tprint(f"Warning: download failed for {url} (exit={rc})")\n\n\tprint("Process complete.")\n\treturn 0\n\n\nif __name__ == "__main__":\n\traise SystemExit(main())\n'


_WINDOWS_IMPL = 'from __future__ import annotations\n\nfrom pathlib import Path\n\nfrom _windows_common_ import apply_proxy_env_from_config, dependency_root, download_file, ensure_dir, load_config, project_root, resolve_path\n\n\ndef main() -> int:\n    root = project_root(__file__)\n    cfg = load_config(root)\n    env = dict(__import__("os").environ)\n    apply_proxy_env_from_config(cfg, env)\n\n    dep_root = dependency_root(root, cfg)\n    ensure_dir(dep_root / "python_packages")\n\n    gguf_dir = resolve_path(root, cfg.get("gguf_dir"), "./MODELS/gguf")\n    ensure_dir(gguf_dir)\n\n    quantizations = cfg.get("llamacpp", {}).get("quantizations", []) or []\n    if not quantizations:\n        raise RuntimeError("llamacpp.quantizations is empty in config.yaml")\n\n    gguf_models = cfg.get("gguf_models", {}) or {}\n    for quant in quantizations:\n        quant = str(quant).strip()\n        if not quant:\n            continue\n        q_dir = ensure_dir(gguf_dir / quant)\n        urls = gguf_models.get(quant, []) or []\n        for url in urls:\n            url = str(url).strip()\n            if not url.startswith("http"):\n                continue\n            name = url.split("/")[-1].split("?")[0]\n            dest = q_dir / name\n            if dest.is_file():\n                print(f"Skipping existing: {dest}")\n                continue\n            print(f"Downloading [{quant}] {url}")\n            download_file(url, dest, env)\n\n    print("GGUF download step completed")\n    return 0\n\n\nif __name__ == "__main__":\n    raise SystemExit(main())\n'


if __name__ == '__main__':
    raise SystemExit(main())
