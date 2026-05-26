from __future__ import annotations

from pathlib import Path

from _native import apply_proxy_env_from_config, dependency_root, download_file, ensure_dir, load_config, project_root, resolve_path


def main() -> int:
    root = project_root(__file__)
    cfg = load_config(root)
    env = dict(__import__("os").environ)
    apply_proxy_env_from_config(cfg, env)

    dep_root = dependency_root(root, cfg)
    ensure_dir(dep_root / "python_packages")

    gguf_dir = resolve_path(root, cfg.get("gguf_dir"), "./MODELS/gguf")
    ensure_dir(gguf_dir)

    quantizations = cfg.get("llamacpp", {}).get("quantizations", []) or []
    if not quantizations:
        raise RuntimeError("llamacpp.quantizations is empty in config.yaml")

    gguf_models = cfg.get("gguf_models", {}) or {}
    for quant in quantizations:
        quant = str(quant).strip()
        if not quant:
            continue
        q_dir = ensure_dir(gguf_dir / quant)
        urls = gguf_models.get(quant, []) or []
        for url in urls:
            url = str(url).strip()
            if not url.startswith("http"):
                continue
            name = url.split("/")[-1].split("?")[0]
            dest = q_dir / name
            if dest.is_file():
                print(f"Skipping existing: {dest}")
                continue
            print(f"Downloading [{quant}] {url}")
            download_file(url, dest, env)

    print("GGUF download step completed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
