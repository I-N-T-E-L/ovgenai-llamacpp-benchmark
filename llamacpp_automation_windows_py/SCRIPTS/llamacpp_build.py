from __future__ import annotations

import json
import os
import re
import shutil
import tempfile
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path

import requests

from _native import (
    apply_dependency_paths,
    apply_proxy_env_from_config,
    dependency_root,
    download_file,
    ensure_dir,
    ensure_tool,
    load_config,
    project_root,
    resolve_path,
    run_cmd,
)

LLAMA_REPO_URL = "https://github.com/ggml-org/llama.cpp"
W64DEVKIT_RELEASES_URL = "https://github.com/skeeto/w64devkit/releases"
W64DEVKIT_RELEASE_LATEST_API = "https://api.github.com/repos/skeeto/w64devkit/releases/latest"

# Keep internal build paths short to avoid Windows path length failures.
BUILD_ROOT_SUBDIR = "llamacpp"
SRC_SUBDIR = "source"
RELEASE_SUBDIR = "Release"
VULKAN_SUBDIR = "ReleaseVulkan"
OV_SUBDIR = "ReleaseOV"


def _llama_bench_candidates(base_dir: Path) -> list[Path]:
    return [
        base_dir / "bin" / "llama-bench.exe",
        base_dir / "bin" / "Release" / "llama-bench.exe",
        base_dir / "llama-bench.exe",
    ]


def find_llama_bench_binary(base_dir: Path) -> Path | None:
    for p in _llama_bench_candidates(base_dir):
        if p.is_file():
            return p
    return None


@dataclass
class BuildPlan:
    full_rebuild: bool
    build_release: bool
    build_vulkan: bool
    build_ov: bool
    reason: str


def _configured_path(root: Path, raw: str | None) -> Path | None:
    if not raw:
        return None
    p = Path(str(raw).strip())
    if p.is_absolute():
        return p
    return (root / p).resolve()


def import_env_from_bat(bat_path: Path, env: dict[str, str]) -> None:
    if not bat_path.is_file():
        raise RuntimeError(f"Configured msvc_env_bat_path does not exist: {bat_path}")

    wrapper_path = Path(tempfile.gettempdir()) / "llamacpp_import_msvc_env.cmd"
    wrapper_path.write_text(
        "\n".join(
            [
                "@echo off",
                f'call "{bat_path}" -host_arch=x64 -arch=x64 >nul 2>&1',
                "if errorlevel 1 exit /b %errorlevel%",
                "set",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    try:
        proc = run_cmd(["cmd.exe", "/d", "/c", str(wrapper_path)], env=env, check=False, capture_output=True)
        out = (proc.stdout or "").strip()
        if proc.returncode != 0 or not out:
            err = (proc.stderr or "").strip()
            raise RuntimeError(
                f"Failed to import MSVC environment from: {bat_path}. "
                f"rc={proc.returncode}; stderr={err[:300]}"
            )

        imported = 0
        for line in out.splitlines():
            if "=" not in line:
                continue
            key, val = line.split("=", 1)
            if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
                continue
            env[key] = val
            imported += 1

        if imported == 0 or ("VSCMD_VER" not in env and "VCINSTALLDIR" not in env):
            raise RuntimeError(f"Failed to import MSVC environment from: {bat_path}. Imported={imported}")
    finally:
        if wrapper_path.exists():
            wrapper_path.unlink(missing_ok=True)


def _read_json_url(url: str, env: dict[str, str]) -> dict:
    proxies = {
        "http": env.get("HTTP_PROXY") or env.get("http_proxy"),
        "https": env.get("HTTPS_PROXY") or env.get("https_proxy"),
    }
    resp = requests.get(
        url,
        timeout=45,
        proxies=proxies,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "llamacpp-build-script",
        },
    )
    resp.raise_for_status()
    return resp.json()


def _detect_w64_root(path: Path) -> Path | None:
    direct_bin = path / "bin"
    if (direct_bin / "x86_64-w64-mingw32-gcc.exe").is_file():
        return path

    for gcc in path.rglob("x86_64-w64-mingw32-gcc.exe"):
        parent = gcc.parent
        if parent.name.lower() == "bin":
            return parent.parent
    return None


def resolve_latest_w64devkit_release(env: dict[str, str]) -> tuple[str, str]:
    print(f"Checking w64devkit releases: {W64DEVKIT_RELEASES_URL}")
    release = _read_json_url(W64DEVKIT_RELEASE_LATEST_API, env)
    tag = str(release.get("tag_name", "")).strip()
    if not tag:
        raise RuntimeError("Failed to resolve latest w64devkit release tag from GitHub")

    assets = release.get("assets", []) or []
    asset_url = ""
    for asset in assets:
        name = str(asset.get("name", "")).lower()
        if "w64devkit" not in name:
            continue
        if name.endswith(".zip") or name.endswith(".7z.exe"):
            asset_url = str(asset.get("browser_download_url", "")).strip()
            if asset_url:
                break
    if not asset_url:
        raise RuntimeError("Failed to find a supported asset (.zip or .7z.exe) for latest w64devkit release")
    return tag, asset_url


def _extract_w64_archive(archive: Path, extract_root: Path, env: dict[str, str]) -> None:
    low_name = archive.name.lower()
    if low_name.endswith(".zip"):
        with zipfile.ZipFile(archive, "r") as zf:
            zf.extractall(extract_root)
        return

    if low_name.endswith(".7z.exe"):
        # w64devkit publishes self-extracting 7z archives as .7z.exe.
        run_cmd([str(archive), "-y", f"-o{extract_root}"], env=env)
        return

    raise RuntimeError(f"Unsupported w64devkit archive type: {archive.name}")


def ensure_w64devkit(dep_root: Path, build_root: Path, env: dict[str, str]) -> Path:
    w64_root = dep_root / "w64devkit"
    detected_root = _detect_w64_root(w64_root) if w64_root.exists() else None
    if detected_root is not None:
        return detected_root

    latest_tag, latest_asset_url = resolve_latest_w64devkit_release(env)

    ensure_dir(build_root)
    archive_name = latest_asset_url.rsplit("/", 1)[-1]
    archive = build_root / archive_name
    print(f"w64devkit not found under {w64_root}; downloading {latest_tag}: {latest_asset_url}")
    download_file(latest_asset_url, archive, env)

    extract_root = dep_root / "w64devkit_extract"
    keep_extract_root = False
    try:
        if extract_root.exists() and not remove_tree_with_retries(extract_root):
            raise RuntimeError(f"Failed to clean temporary w64devkit extract root (locked): {extract_root}")
        ensure_dir(extract_root)
        _extract_w64_archive(archive, extract_root, env)

        extracted_root = _detect_w64_root(extract_root)
        if extracted_root is None:
            raise RuntimeError(f"Downloaded w64devkit archive does not contain expected compilers under {extract_root}")

        if w64_root.exists() and not remove_tree_with_retries(w64_root):
            print(f"Warning: could not fully clean existing w64devkit dir (locked): {w64_root}")

        try:
            shutil.move(str(extracted_root), str(w64_root))
            print(f"Installed w64devkit: {w64_root}")
            return w64_root
        except Exception as exc:
            print(f"Warning: move-based w64devkit install failed ({exc}); trying copy-based fallback")

            try:
                shutil.copytree(extracted_root, w64_root, dirs_exist_ok=True)
                detected_root = _detect_w64_root(w64_root)
                if detected_root is not None:
                    print(f"Installed w64devkit via copy fallback: {w64_root}")
                    return detected_root
            except Exception as copy_exc:
                print(f"Warning: copy-based w64devkit install failed ({copy_exc}); using extracted toolchain path")

            detected_root = _detect_w64_root(extracted_root)
            if detected_root is not None:
                keep_extract_root = True
                print(f"Using extracted w64devkit in-place: {detected_root}")
                return detected_root

            raise RuntimeError(f"Failed to install usable w64devkit under {w64_root} and {extract_root}")
    finally:
        if extract_root.exists() and not keep_extract_root:
            shutil.rmtree(extract_root, ignore_errors=True)
        if archive.exists():
            archive.unlink(missing_ok=True)


def detect_compiler(dep_root: Path, env: dict[str, str], toolchain: str, root: Path, cfg: dict, build_root: Path | None = None) -> tuple[str, list[str]]:
    toolchain = toolchain.strip().lower()
    ll_cfg = cfg.get("llamacpp", {}) or {}

    if toolchain == "w64devkit":
        if build_root is None:
            build_root = dep_root / "llama.cpp" / "build"
        w64_root = ensure_w64devkit(dep_root, build_root, env)
        w64_bin = w64_root / "bin"
        gcc = w64_bin / "x86_64-w64-mingw32-gcc.exe"
        gxx = w64_bin / "x86_64-w64-mingw32-g++.exe"
        if (not gcc.is_file()) or (not gxx.is_file()):
            raise RuntimeError(
                "w64devkit toolchain selected, but gcc/g++ were not found under "
                f"{w64_bin}."
            )

        env["PATH"] = str(w64_bin) + os.pathsep + env.get("PATH", "")
        env["CC"] = gcc.as_posix()
        env["CXX"] = gxx.as_posix()
        for k in ["RC", "CMAKE_RC_COMPILER", "CMAKE_MT", "LIB", "LIBPATH", "INCLUDE"]:
            env.pop(k, None)
        return "w64devkit", [f"-DCMAKE_C_COMPILER={gcc.as_posix()}", f"-DCMAKE_CXX_COMPILER={gxx.as_posix()}"]

    if toolchain != "msvc":
        raise RuntimeError("toolchain must be one of: msvc, w64devkit")

    msvc_env_bat_cfg = _configured_path(root, ll_cfg.get("msvc_env_bat_path"))
    if msvc_env_bat_cfg is None:
        raise RuntimeError("llamacpp.msvc_env_bat_path is required. Point it to VsDevCmd.bat or vcvars64.bat.")

    import_env_from_bat(msvc_env_bat_cfg, env)

    print(f"MSVC configured via msvc_env_bat_path: {msvc_env_bat_cfg}")
    return "msvc", []


def find_setupvars_root(ov_root: Path) -> Path | None:
    if (ov_root / "setupvars.bat").is_file():
        return ov_root
    hits = sorted(ov_root.rglob("setupvars.bat")) if ov_root.exists() else []
    return hits[-1].parent if hits else None


def parse_ov_semver_from_url(url: str) -> str:
    m = re.search(r"openvino_toolkit_windows_([0-9]+\.[0-9]+(?:\.[0-9]+)?)\.", url)
    return m.group(1) if m else ""


def detect_ov_semver(ov_runtime_root: Path | None) -> str:
    if ov_runtime_root is None:
        return ""
    vfile = ov_runtime_root / "runtime" / "version.txt"
    if not vfile.is_file():
        return ""
    first = vfile.read_text(encoding="utf-8", errors="ignore").splitlines()[0].strip()
    m = re.search(r"([0-9]+\.[0-9]+(?:\.[0-9]+)?)", first)
    return m.group(1) if m else ""


def resolve_latest_openvino_url(env: dict[str, str]) -> str:
    import requests

    proxies = {
        "http": env.get("HTTP_PROXY") or env.get("http_proxy"),
        "https": env.get("HTTPS_PROXY") or env.get("https_proxy"),
    }
    r = requests.get("https://storage.openvinotoolkit.org/filetree.json", timeout=60, proxies=proxies)
    r.raise_for_status()
    data = r.json()

    repos = next((n for n in data.get("children", []) if n.get("name") == "repositories"), None)
    ov = next((n for n in (repos or {}).get("children", []) if n.get("name") == "openvino"), None)
    pkgs = next((n for n in (ov or {}).get("children", []) if n.get("name") == "packages"), None)
    if not pkgs:
        return ""

    versions: list[tuple[tuple[int, int, int], dict]] = []
    for child in pkgs.get("children", []):
        name = str(child.get("name", ""))
        if re.match(r"^\d{4}\.\d+(?:\.\d+)?$", name):
            parts = [int(x) for x in name.split(".")]
            while len(parts) < 3:
                parts.append(0)
            versions.append((tuple(parts), child))
    if not versions:
        return ""

    versions.sort(key=lambda x: x[0])
    chosen = versions[-1][1]
    win = next((n for n in chosen.get("children", []) if n.get("name") == "windows"), None)
    if not win:
        return ""

    zips: list[str] = []
    for f in win.get("children", []):
        if f.get("type") != "file":
            continue
        name = str(f.get("name", ""))
        low = name.lower()
        if not name.startswith("openvino_toolkit_windows_"):
            continue
        if not name.endswith("_x86_64.zip"):
            continue
        if low.startswith("pdb_") or "_vc_mt_" in low or "nightly" in low or ".dev" in low:
            continue
        zips.append(name)
    if not zips:
        return ""

    zips.sort()
    return f"https://storage.openvinotoolkit.org/repositories/openvino/packages/{chosen.get('name')}/windows/{zips[-1]}"


def resolve_openvino_url(cfg: dict, env: dict[str, str]) -> str:
    ov_cfg = cfg.get("openvino", {}) or {}
    mode = str(ov_cfg.get("version", "default") or "default").strip().lower()
    if mode not in {"default", "latest"}:
        raise RuntimeError("openvino.version must be 'default' or 'latest'")
    if mode == "latest":
        latest = resolve_latest_openvino_url(env)
        if not latest:
            raise RuntimeError("Could not resolve latest OpenVINO package URL")
        return latest

    url = str(ov_cfg.get("default_url", "")).strip()
    if not url:
        raise RuntimeError("openvino.default_url is missing")
    return url


def ensure_openvino(cfg: dict, dep_root: Path, build_root: Path, env: dict[str, str]) -> tuple[Path, str]:
    ov_root = dep_root / "openvino"
    desired_url = resolve_openvino_url(cfg, env)
    desired_semver = parse_ov_semver_from_url(desired_url)

    setup = find_setupvars_root(ov_root)
    installed_semver = detect_ov_semver(setup)
    needs_install = setup is None
    if desired_semver and installed_semver and desired_semver != installed_semver:
        needs_install = True

    if needs_install:
        ensure_dir(build_root)
        archive = build_root / "openvino_runtime.zip"
        print(f"Downloading OpenVINO runtime: {desired_url}")
        download_file(desired_url, archive, env)
        try:
            if ov_root.exists():
                shutil.rmtree(ov_root, ignore_errors=True)
            ensure_dir(ov_root)
            with zipfile.ZipFile(archive, "r") as zf:
                zf.extractall(ov_root)

            setup = find_setupvars_root(ov_root)
            if setup is None:
                raise RuntimeError(f"OpenVINO setupvars.bat not found under {ov_root}")
            installed_semver = detect_ov_semver(setup)
        finally:
            if archive.exists():
                archive.unlink(missing_ok=True)

    return setup, installed_semver


def build_target_exists(build_root: Path, subdir: str) -> bool:
    return find_llama_bench_binary(build_root / subdir) is not None


def load_logged_commit(log_file: Path) -> str:
    if not log_file.is_file():
        return ""
    lines = log_file.read_text(encoding="utf-8", errors="ignore").splitlines()
    if not lines:
        return ""
    return lines[0].split()[0].strip()


def write_commit_log(git: str, src_dir: Path, log_file: Path, env: dict[str, str]) -> None:
    full_commit = run_cmd([git, "-C", str(src_dir), "rev-parse", "HEAD"], env=env, capture_output=True).stdout.strip()
    short = full_commit[:9]
    subject = run_cmd([git, "-C", str(src_dir), "log", "-1", "--format=%s"], env=env, capture_output=True).stdout.strip()
    ensure_dir(log_file.parent)
    log_file.write_text(f"{short} {subject}\n", encoding="utf-8")


def write_ov_log(ov_log_file: Path, ov_semver: str) -> None:
    if not ov_semver:
        return
    ensure_dir(ov_log_file.parent)
    ov_log_file.write_text(ov_semver + "\n", encoding="utf-8")


def cmake_configure_and_build(
    cmake: str,
    src_dir: Path,
    out_dir: Path,
    args: list[str],
    env: dict[str, str],
    build_target: str = "llama-bench",
    compiler_mode: str = "msvc",
) -> None:
    _ = compiler_mode
    run_cmd([cmake, "-S", str(src_dir), "-B", str(out_dir), "-G", "Ninja", *args], env=env)
    jobs = str(env.get("LLAMACPP_BUILD_JOBS", "1")).strip() or "1"
    # Stream build logs live so long steps don't appear stuck.
    run_cmd([cmake, "--build", str(out_dir), "--target", build_target, "--parallel", jobs], env=env)


def _activate_vulkan_sdk(sdk_dir: Path, env: dict[str, str]) -> bool:
    bin_dir = sdk_dir / "Bin"
    glslc_exe = bin_dir / "glslc.exe"
    include_dir = sdk_dir / "Include"
    lib_file = sdk_dir / "Lib" / "vulkan-1.lib"
    if not (bin_dir.is_dir() and glslc_exe.is_file() and include_dir.is_dir() and lib_file.is_file()):
        return False

    env["PATH"] = str(bin_dir) + os.pathsep + env.get("PATH", "")
    env["VULKAN_SDK"] = str(sdk_dir)
    env["VK_SDK_PATH"] = str(sdk_dir)
    return True


def _is_valid_vulkan_sdk_dir(sdk_dir: Path) -> bool:
    return (
        (sdk_dir / "Bin" / "glslc.exe").is_file()
        and (sdk_dir / "Include").is_dir()
        and (sdk_dir / "Lib" / "vulkan-1.lib").is_file()
    )

def ensure_vulkan_sdk(env: dict[str, str], root: Path, cfg: dict) -> str:
    ll_cfg = cfg.get("llamacpp", {}) or {}
    configured = _configured_path(root, ll_cfg.get("vulkan_sdk_path"))
    if configured is None:
        raise RuntimeError("llamacpp.vulkan_sdk_path is required and must point to an installed Vulkan SDK directory.")

    sdk_dir = configured
    if not _is_valid_vulkan_sdk_dir(sdk_dir):
        raise RuntimeError(
            f"Configured Vulkan SDK path is missing or incomplete: {sdk_dir}. "
            "Expected Bin/glslc.exe, Include/, and Lib/vulkan-1.lib."
        )

    if not _activate_vulkan_sdk(sdk_dir, env):
        raise RuntimeError(f"Failed to activate Vulkan SDK at {sdk_dir}")
    return str(sdk_dir)


def ensure_vcpkg_opencl(dep_root: Path, env: dict[str, str], git: str) -> Path:
    def _first_existing(candidates: list[Path]) -> Path | None:
        for p in candidates:
            if p.is_file():
                return p
        return None

    def _ensure_windows_sdk_tools() -> None:
        # vcpkg/cmake toolchain configuration can fail with CMAKE_MT-NOTFOUND or missing rc.
        # Prefer values from the imported VS environment, then fall back to common SDK locations.
        sdk_bin = Path(str(env.get("WindowsSdkVerBinPath", "")).strip()) if env.get("WindowsSdkVerBinPath") else None
        rc_candidates: list[Path] = []
        mt_candidates: list[Path] = []

        if sdk_bin:
            rc_candidates += [sdk_bin / "x64" / "rc.exe", sdk_bin / "rc.exe"]
            mt_candidates += [sdk_bin / "x64" / "mt.exe", sdk_bin / "mt.exe"]

        progx86 = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"))
        kits_bin = progx86 / "Windows Kits" / "10" / "bin"
        if kits_bin.is_dir():
            # Prefer newest SDK version if available.
            ver_dirs = sorted([p for p in kits_bin.iterdir() if p.is_dir() and p.name[:1].isdigit()], reverse=True)
            for d in ver_dirs:
                rc_candidates.append(d / "x64" / "rc.exe")
                mt_candidates.append(d / "x64" / "mt.exe")

        rc_exe = _first_existing(rc_candidates)
        mt_exe = _first_existing(mt_candidates)

        if rc_exe:
            env["RC"] = str(rc_exe)
            env["CMAKE_RC_COMPILER"] = str(rc_exe)
        if mt_exe:
            env["CMAKE_MT"] = str(mt_exe)

        if not rc_exe or not mt_exe:
            missing = []
            if not rc_exe:
                missing.append("rc.exe")
            if not mt_exe:
                missing.append("mt.exe")
            raise RuntimeError(
                "Missing required Windows SDK tools for MSVC/vcpkg: "
                + ", ".join(missing)
                + ". Install Windows 10/11 SDK in Visual Studio Build Tools and ensure VsDevCmd loads it."
            )

    # Avoid accidental toolchain/root mismatch inherited from external shells.
    env.pop("VCPKG_ROOT", None)
    _ensure_windows_sdk_tools()

    vcpkg_root = dep_root / "vcpkg"
    vcpkg_exe = vcpkg_root / "vcpkg.exe"
    bootstrap_bat = vcpkg_root / "bootstrap-vcpkg.bat"
    toolchain = vcpkg_root / "scripts" / "buildsystems" / "vcpkg.cmake"
    include_cl = vcpkg_root / "installed" / "x64-windows" / "include" / "CL" / "cl.h"
    lib_opencl = vcpkg_root / "installed" / "x64-windows" / "lib" / "OpenCL.lib"

    if not vcpkg_root.is_dir():
        print(f"Cloning vcpkg into: {vcpkg_root}")
        run_cmd([git, "-c", "core.longpaths=true", "clone", "https://github.com/microsoft/vcpkg", str(vcpkg_root)], env=env)

    if not vcpkg_exe.is_file():
        if not bootstrap_bat.is_file():
            raise RuntimeError(f"vcpkg executable not found: {vcpkg_exe}")
        print(f"Bootstrapping vcpkg: {bootstrap_bat}")
        run_cmd(["cmd.exe", "/d", "/c", str(bootstrap_bat), "-disableMetrics"], cwd=vcpkg_root, env=env)

    if not vcpkg_exe.is_file():
        raise RuntimeError(f"vcpkg executable not found after bootstrap: {vcpkg_exe}")

    if not include_cl.is_file() or not lib_opencl.is_file():
        print("Ensuring OpenCL headers/libs via vcpkg...")
        run_cmd(
            [str(vcpkg_exe), "install", "opencl:x64-windows", "--recurse", "--clean-after-build"],
            cwd=vcpkg_root,
            env=env,
        )

    if not include_cl.is_file() or not lib_opencl.is_file():
        raise RuntimeError("OpenCL headers/libs not found after vcpkg install (expected include/CL/cl.h and lib/OpenCL.lib)")

    if not toolchain.is_file():
        raise RuntimeError(f"vcpkg toolchain file not found: {toolchain}")
    return toolchain


def build_plan(
    cfg: dict,
    build_root: Path,
    llama_log: Path,
    ov_log: Path,
    auto_update: bool,
    remote_head: str,
    ov_semver: str,
) -> BuildPlan:
    run_matrix = cfg.get("run_matrix") or {}
    cpu_rm = run_matrix.get("cpu") or {}
    gpu_rm = run_matrix.get("gpu") or {}
    npu_rm = run_matrix.get("npu") or {}

    want_release = bool(cpu_rm.get("llamacpp_ggml_cpu", True))
    want_vulkan = bool(gpu_rm.get("llamacpp_vulkan_gpu", True))
    want_ov = bool(
        cpu_rm.get("llamacpp_ov_cpu", True)
        or gpu_rm.get("llamacpp_ov_gpu", True)
        or npu_rm.get("llamacpp_ov_npu", True)
    )

    logged = load_logged_commit(llama_log)
    remote_short = remote_head[: len(logged)] if logged and remote_head else ""
    same_commit = True
    if auto_update:
        same_commit = bool(logged and remote_short == logged)

    logged_ov_semver = load_logged_commit(ov_log)
    ov_version_changed = bool(auto_update and ov_semver and logged_ov_semver and ov_semver != logged_ov_semver)

    if not same_commit:
        # Rule: if llama.cpp commit changed/missing, rebuild all three backends.
        return BuildPlan(
            True,
            want_release,
            want_vulkan,
            want_ov,
            "commit changed or missing: rebuild enabled backends",
        )

    # Rule: with same commit, build only missing backends.
    build_release = not build_target_exists(build_root, RELEASE_SUBDIR)
    build_vulkan = not build_target_exists(build_root, VULKAN_SUBDIR)
    build_ov = not build_target_exists(build_root, OV_SUBDIR)

    if not want_release:
        build_release = False
    if not want_vulkan:
        build_vulkan = False
    if not want_ov:
        build_ov = False

    # Rule: if OpenVINO runtime version changed, rebuild only ReleaseOV.
    if ov_version_changed:
        build_ov = True

    reason = "incremental: build only missing backends"
    if ov_version_changed:
        reason = f"openvino changed ({logged_ov_semver} -> {ov_semver}): rebuild ReleaseOV"

    return BuildPlan(False, build_release, build_vulkan, build_ov, reason)


def is_git_repo(git: str, path: Path, env: dict[str, str]) -> bool:
    if not path.is_dir():
        return False
    probe = run_cmd([git, "-C", str(path), "rev-parse", "--is-inside-work-tree"], env=env, check=False, capture_output=True)
    return probe.returncode == 0 and probe.stdout.strip().lower() == "true"


def remove_tree_with_retries(path: Path, retries: int = 4, delay_s: float = 0.5) -> bool:
    if not path.exists():
        return True
    for _ in range(retries):
        try:
            shutil.rmtree(path)
        except Exception:
            time.sleep(delay_s)
        if not path.exists():
            return True
    return not path.exists()


def find_existing_source_repo(build_root: Path, git: str, env: dict[str, str]) -> Path | None:
    candidates: list[Path] = []
    fresh_prefix = f"{SRC_SUBDIR}_fresh"
    for p in build_root.iterdir() if build_root.exists() else []:
        if not p.is_dir():
            continue
        if p.name == SRC_SUBDIR or p.name.startswith(fresh_prefix):
            if is_git_repo(git, p, env):
                candidates.append(p)
    if not candidates:
        return None
    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0]


def cleanup_stale_source_dirs(build_root: Path, active_src: Path) -> None:
    fresh_prefix = f"{SRC_SUBDIR}_fresh"
    for p in build_root.iterdir() if build_root.exists() else []:
        if not p.is_dir() or p == active_src:
            continue
        if p.name == SRC_SUBDIR or p.name.startswith(fresh_prefix):
            remove_tree_with_retries(p)


def prepare_llama_source_dir(git: str, build_root: Path, src_dir: Path, env: dict[str, str]) -> Path:
    _ = build_root
    if is_git_repo(git, src_dir, env):
        return src_dir

    reusable = find_existing_source_repo(build_root, git, env)
    if reusable is not None:
        print(f"Reusing existing source repo: {reusable}")
        cleanup_stale_source_dirs(build_root, reusable)
        return reusable

    if src_dir.exists():
        print(f"Source directory exists but is not a git repo, recreating: {src_dir}")
        remove_tree_with_retries(src_dir)
        if src_dir.exists():
            # If old files are locked, clone into a fresh sibling directory.
            fresh = build_root / f"{SRC_SUBDIR}_fresh"
            idx = 1
            while fresh.exists():
                idx += 1
                fresh = build_root / f"{SRC_SUBDIR}_fresh_{idx}"
            print(f"Source directory is locked; using fresh clone dir: {fresh}")
            src_dir = fresh

    run_cmd([git, "-c", "core.longpaths=true", "clone", LLAMA_REPO_URL, str(src_dir)], env=env)

    if not is_git_repo(git, src_dir, env):
        raise RuntimeError(f"Source directory is still not a git repository after clone: {src_dir}")

    cleanup_stale_source_dirs(build_root, src_dir)

    return src_dir


def patch_vulkan_shader_gen_parallelism(src_dir: Path) -> None:
    gen_cpp = src_dir / "ggml" / "src" / "ggml-vulkan" / "vulkan-shaders" / "vulkan-shaders-gen.cpp"
    if not gen_cpp.is_file():
        return

    text = gen_cpp.read_text(encoding="utf-8", errors="ignore")
    old = "uint32_t N = std::max(1u, std::min(16u, std::thread::hardware_concurrency()));"
    new = "uint32_t N = 1;"
    if old in text:
        text = text.replace(old, new, 1)
        gen_cpp.write_text(text, encoding="utf-8")
        print("Patched vulkan-shaders-gen parallelism: forcing single-thread glslc worker")


def main() -> int:
    root = project_root(__file__)
    cfg = load_config(root)
    env = dict(os.environ)
    apply_proxy_env_from_config(cfg, env)

    dep_root = dependency_root(root, cfg)
    ensure_dir(dep_root)
    apply_dependency_paths(dep_root, env)

    git = ensure_tool("git", dep_root, env)
    cmake = ensure_tool("cmake", dep_root, env)
    _ = ensure_tool("ninja", dep_root, env)

    mode = str((cfg.get("llamacpp", {}) or {}).get("use", "build")).strip().lower()
    if mode != "build":
        raise RuntimeError("Windows native Python workflow supports only llamacpp.use=build")

    build_dir = resolve_path(root, cfg.get("build_dir"), "./BUILD")
    logs_dir = resolve_path(root, cfg.get("logs_dir"), "./logs")
    ensure_dir(logs_dir)

    build_root = build_dir / BUILD_ROOT_SUBDIR
    src_dir = build_root / SRC_SUBDIR
    llama_log = logs_dir / f"llama_cpp_commit_{mode}.txt"
    ov_log = logs_dir / f"ov_build_info_{mode}.txt"

    ll_cfg = cfg.get("llamacpp", {}) or {}
    top_auto_update = cfg.get("auto_update")
    if top_auto_update is None:
        top_auto_update = ll_cfg.get("auto_update", "true")
    auto_update = str(top_auto_update).strip().lower() in {"true", "1", "yes"}
    print(f"llamacpp.auto_update={auto_update}")

    ov_runtime_root, ov_semver = ensure_openvino(cfg, dep_root, build_root, env)

    remote_head = ""
    if auto_update:
        remote_head = run_cmd([git, "ls-remote", LLAMA_REPO_URL, "HEAD"], env=env, capture_output=True).stdout.split()[0].strip()

    plan = build_plan(
        cfg,
        build_root,
        llama_log,
        ov_log,
        auto_update,
        remote_head,
        ov_semver,
    )
    print(f"Build plan: {plan.reason}")

    # Hardcoded split requested by user:
    # - MSVC for Release and ReleaseOV
    # - w64devkit for ReleaseVulkan
    msvc_env = dict(env)
    msvc_mode, msvc_compiler_args = detect_compiler(dep_root, msvc_env, "msvc", root, cfg, build_root)

    w64_env = dict(env)
    w64_mode, w64_compiler_args = detect_compiler(dep_root, w64_env, "w64devkit", root, cfg, build_root)

    vcpkg_toolchain: Path | None = None
    if plan.build_ov:
        vcpkg_toolchain = ensure_vcpkg_opencl(dep_root, msvc_env, git)

    if plan.full_rebuild and build_root.exists():
        if not remove_tree_with_retries(build_root):
            print(f"Warning: could not fully clean build root (likely locked files): {build_root}")
    ensure_dir(build_root)

    src_dir = prepare_llama_source_dir(git, build_root, src_dir, env)

    if plan.build_vulkan:
        patch_vulkan_shader_gen_parallelism(src_dir)

    write_commit_log(git, src_dir, llama_log, env)

    if plan.build_release:
        print("--- Build: Release (CPU) ---")
        out = build_root / RELEASE_SUBDIR
        if out.exists():
            if not remove_tree_with_retries(out):
                raise RuntimeError(f"Failed to clean output directory (locked): {out}")
        cmake_configure_and_build(
            cmake,
            src_dir,
            out,
            [
                "-DCMAKE_BUILD_TYPE=Release",
                "-DGGML_VULKAN=OFF",
                "-DBUILD_SHARED_LIBS=OFF",
                "-DLLAMA_BUILD_UI=OFF",
                *msvc_compiler_args,
            ],
            msvc_env,
            compiler_mode=msvc_mode,
        )
    else:
        print("--- Skip: Release (CPU) ---")

    if plan.build_vulkan:
        print("--- Build: ReleaseVulkan ---")
        _ = ensure_vulkan_sdk(w64_env, root, cfg)

        out = build_root / VULKAN_SUBDIR
        drive = os.environ.get("SystemDrive", "C:").rstrip("\\/")
        drive_root = Path(drive + "\\")
        short_root = drive_root / "_llv"

        if short_root.exists() and not remove_tree_with_retries(short_root):
            fallback = None
            for idx in range(2, 10):
                candidate = drive_root / f"_llv_{idx}"
                if candidate.exists() and not remove_tree_with_retries(candidate):
                    continue
                fallback = candidate
                break
            if fallback is None:
                raise RuntimeError(f"Failed to clean Vulkan short build root (locked): {short_root}")
            print(f"Warning: default Vulkan short build root is locked; using alternate: {fallback}")
            short_root = fallback

        short_src = short_root / "s"
        short_out = short_root / "b"
        ensure_dir(short_root)

        print(f"Preparing short Vulkan source path: {short_src}")
        run_cmd([git, "-c", "core.longpaths=true", "clone", str(src_dir), str(short_src)], env=env)
        patch_vulkan_shader_gen_parallelism(short_src)

        vulkan_args = [
            "-DCMAKE_BUILD_TYPE=Release",
            "-DGGML_VULKAN=ON",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DLLAMA_BUILD_UI=OFF",
        ]
        vulkan_sdk = w64_env.get("VULKAN_SDK", "")
        if vulkan_sdk:
            vulkan_args += [
                f"-DVulkan_INCLUDE_DIR={Path(vulkan_sdk) / 'Include'}",
                f"-DVulkan_LIBRARY={Path(vulkan_sdk) / 'Lib' / 'vulkan-1.lib'}",
            ]
        cmake_configure_and_build(cmake, short_src, short_out, [*vulkan_args, *w64_compiler_args], w64_env, compiler_mode=w64_mode)

        built_bench = find_llama_bench_binary(short_out)
        if built_bench is None:
            raise RuntimeError(f"Vulkan build completed but llama-bench.exe not found under: {short_out}")

        if out.exists() and not remove_tree_with_retries(out):
            raise RuntimeError(f"Failed to clean output directory (locked): {out}")
        ensure_dir(out / "bin")
        staged = out / "bin" / "llama-bench.exe"
        shutil.copy2(built_bench, staged)
        print(f"Staged Vulkan llama-bench to canonical output: {staged}")

        if short_root.exists() and not remove_tree_with_retries(short_root):
            print(f"Warning: could not remove Vulkan short build root: {short_root}")

    else:
        print("--- Skip: ReleaseVulkan ---")

    if plan.build_ov:
        print("--- Build: ReleaseOV ---")
        out = build_root / OV_SUBDIR
        if out.exists():
            if not remove_tree_with_retries(out):
                raise RuntimeError(f"Failed to clean output directory (locked): {out}")
        args = [
            "-DCMAKE_BUILD_TYPE=Release",
            "-DGGML_OPENVINO=ON",
            "-DLLAMA_CURL=OFF",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DLLAMA_BUILD_UI=OFF",
            f"-DOpenVINO_DIR={ov_runtime_root / 'runtime' / 'cmake'}",
        ]
        if vcpkg_toolchain and vcpkg_toolchain.is_file():
            args.append(f"-DCMAKE_TOOLCHAIN_FILE={vcpkg_toolchain}")

        cmake_configure_and_build(cmake, src_dir, out, [*args, *msvc_compiler_args], msvc_env, compiler_mode=msvc_mode)
        write_ov_log(ov_log, ov_semver)
    else:
        print("--- Skip: ReleaseOV ---")

    print("All requested builds completed.")
    print(f"Build root: {build_root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
