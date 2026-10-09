#!/usr/bin/env python
"""Build the GADS GDExtension (native/) into addons/gads/native/bin/.

    python tools/build_native.py                  # this platform (linux or windows)
    python tools/build_native.py linux windows    # Windows cross-built with MinGW on Linux
    python tools/build_native.py linux windows linux_arm64   # and Linux ARM64 (aarch64-linux-gnu-g++)
    python tools/build_native.py android          # Android arm64 + x86_64 (one .so each)
    python tools/build_native.py web              # Web wasm32, threaded (SharedArrayBuffer)
    python tools/build_native.py web_nothreads    # Web wasm32, single-threaded fallback
    python tools/build_native.py macos            # macOS universal .framework (needs a Mac)
    python tools/build_native.py ios              # iOS arm64 .xcframework (needs a Mac)
    python tools/build_native.py --hash           # print the source hash the library embeds

Clones godot-cpp at the pinned revision into native/godot-cpp on first use. Needs SCons and a
C++17 compiler for each target:

    windows       Visual Studio Build Tools (MSVC); on Linux cross-build with use_mingw=yes.
    linux         g++ (linux_arm64 cross-builds with g++-aarch64-linux-gnu).
    android       the Android NDK named by godot-cpp (ndk;{ndk}); set ANDROID_HOME to the SDK
                  (NDK at $ANDROID_HOME/ndk/{ndk}) or ANDROID_NDK_ROOT straight to the NDK.
    web           Emscripten {emsdk} (match the engine's web template; run from a shell with
                  emsdk_env sourced so emcc is on PATH). web_nothreads needs a native source
                  change (see native/src/tess/parallel.h) - rebuild every platform then.
    macos / ios   a Mac with Xcode command line tools.

Only template_release is built. The library embeds a hash of native/src and native/thirdparty, so
if the native sources change every committed binary must be rebuilt to carry the same hash.
"""
from __future__ import annotations

import hashlib
import os
import platform
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NATIVE = ROOT / "native"
GODOT_CPP = NATIVE / "godot-cpp"
GODOT_CPP_URL = "https://github.com/godotengine/godot-cpp"
# godot-cpp v10 (master, 2026-10): targets Godot 4.7 through api_version.
GODOT_CPP_COMMIT = "507ed9d840c01a3c5b2a39af8bb4000bfac30bf5"
# The NDK godot-cpp's tools/android.py expects at the pinned commit; install this exact one.
ANDROID_NDK_VERSION = "28.1.13356709"


def source_hash() -> str:
    """The hash native/SConstruct embeds (keep the two in step)."""
    files = []
    for top in ("src", "thirdparty"):
        for dirpath, _, names in os.walk(NATIVE / top):
            for name in names:
                if name.endswith((".h", ".hpp", ".c", ".cpp")) and not name.endswith(".gen.h"):
                    files.append(Path(dirpath, name).relative_to(NATIVE).as_posix())
    h = hashlib.sha256()
    for rel in sorted(files):
        h.update(rel.encode("utf-8") + b"\n")
        h.update((NATIVE / rel).read_bytes())
    return h.hexdigest()[:16]


def ensure_godot_cpp() -> None:
    if (GODOT_CPP / "SConstruct").exists():
        current = subprocess.run(["git", "rev-parse", "HEAD"], cwd=GODOT_CPP, capture_output=True, text=True).stdout.strip()
        if current == GODOT_CPP_COMMIT:
            return
        subprocess.run(["git", "fetch", "--depth", "1", "origin", GODOT_CPP_COMMIT], cwd=GODOT_CPP, check=True)
        subprocess.run(["git", "checkout", "-q", GODOT_CPP_COMMIT], cwd=GODOT_CPP, check=True)
        return
    GODOT_CPP.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q"], cwd=GODOT_CPP, check=True)
    subprocess.run(["git", "remote", "add", "origin", GODOT_CPP_URL], cwd=GODOT_CPP, check=True)
    subprocess.run(["git", "fetch", "--depth", "1", "origin", GODOT_CPP_COMMIT], cwd=GODOT_CPP, check=True)
    subprocess.run(["git", "checkout", "-q", "FETCH_HEAD"], cwd=GODOT_CPP, check=True)


def runs_for(target: str) -> list[tuple[str, list[str]]]:
    """A target maps to one or more SCons runs: (godot-cpp platform, extra args).

    Android builds both ABIs (arm64 for phones, x86_64 for emulators) in one target. Web is
    threaded by default; the nothreads variant is a separate target because it changes behaviour.
    """
    return {
        "linux_arm64": [("linux", ["arch=arm64"])],
        "android": [("android", ["arch=arm64", f"ndk_version={ANDROID_NDK_VERSION}"]),
                    ("android", ["arch=x86_64", f"ndk_version={ANDROID_NDK_VERSION}"])],
        "web": [("web", [])],
        "web_nothreads": [("web", ["threads=no"])],
        "macos": [("macos", ["arch=universal"])],
        "ios": [("ios", ["arch=arm64"])],
    }.get(target, [(target, [])])


def build(target: str) -> int:
    for target_platform, extra in runs_for(target):
        env = dict(os.environ)
        if target == "linux_arm64" and platform.machine().lower() not in ("aarch64", "arm64"):
            # Cross-built with the GNU toolchain (apt: g++-aarch64-linux-gnu).
            env["GADS_CROSS_PREFIX"] = "aarch64-linux-gnu"
        args = ["scons", f"platform={target_platform}", "target=template_release", "optimize=speed",
                "debug_symbols=no", f"-j{os.cpu_count() or 4}"] + extra
        if target_platform == "windows" and platform.system() != "Windows":
            args.append("use_mingw=yes")
        print("[build_native]", " ".join(args), flush=True)
        rc = subprocess.run(args, cwd=NATIVE, env=env).returncode
        if rc != 0:
            return rc
    return 0


def main(argv: list[str]) -> int:
    if "--hash" in argv:
        print(source_hash())
        return 0
    targets = [a for a in argv if not a.startswith("-")] or [{"Linux": "linux", "Windows": "windows"}.get(platform.system(), "linux")]
    ensure_godot_cpp()
    for t in targets:
        if build(t) != 0:
            return 1
    print(f"[build_native] source hash {source_hash()}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
