#!/usr/bin/env python
"""Build the GADS GDExtension (native/) into addons/gads/native/bin/.

    python tools/build_native.py                  # this platform (linux or windows)
    python tools/build_native.py linux windows    # Windows cross-built with MinGW on Linux
    python tools/build_native.py --hash           # print the source hash the library embeds

Clones godot-cpp at the pinned revision into native/godot-cpp on first use. Needs SCons and a
C++17 compiler (on Linux for Windows: the posix-threads MinGW, x86_64-w64-mingw32-g++-posix).
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


def build(target_platform: str) -> int:
    args = ["scons", f"platform={target_platform}", "target=template_release", "optimize=speed", "debug_symbols=no",
            f"-j{os.cpu_count() or 4}"]
    if target_platform == "windows" and platform.system() != "Windows":
        args.append("use_mingw=yes")
    print("[build_native]", " ".join(args), flush=True)
    return subprocess.run(args, cwd=NATIVE).returncode


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
