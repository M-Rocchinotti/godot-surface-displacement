#!/usr/bin/env python
"""Exercise the GADS editor plugin in a real (headed) editor.

Builds build/editor_check/ from the shipped archive (addons/gads as users
download it, see shipped_archive.py), a small test plugin (tests/editor_check/
editor_check_plugin.gd) and a generated scene, then starts the editor. The test plugin runs the
Tools menu actions (add the node, add a field for the selected ground, convert materials, bake
the ground, validate, prepare a height map, make a mesh a GADSMeshInstance3D and bake it), checks undo/redo and what an editor save writes,
prints "EDITOR CHECK OK" and quits. Fails on a failed check, engine errors or leak reports in
the logs. Exit code 0 = passed.

    python tests/run_editor_check.py
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

from log_scan import problems_in
import shipped_archive

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / "build" / "editor_check"

PROJECT = """config_version=5

[application]

config/name="GADS editor check"
config/features=PackedStringArray("4.7", "Forward Plus")

[editor_plugins]

enabled=PackedStringArray("res://addons/gads/plugin.cfg", "res://addons/gads_editor_check/plugin.cfg")
"""

CHECK_CFG = """[plugin]

name="GADS editor check"
description="Test-only plugin."
author="tests"
version="1.0"
script="editor_check_plugin.gd"
"""


def run(args: list[str]) -> tuple[int, str]:
    proc = subprocess.run([sys.executable, str(DEST / "tools" / "godot.py"), "--timeout", "300"] + args,
                          cwd=DEST, capture_output=True, text=True, encoding="utf-8", errors="replace")
    return proc.returncode, proc.stdout + proc.stderr


def main() -> int:
    if DEST.exists():
        shutil.rmtree(DEST)
    DEST.mkdir(parents=True)
    shipped_archive.extract(DEST)
    (DEST / "tools").mkdir()
    if (ROOT / "tools" / ".godot_path").exists():
        shutil.copy2(ROOT / "tools" / ".godot_path", DEST / "tools" / ".godot_path")
    shutil.copy2(ROOT / "tools" / "godot.py", DEST / "tools" / "godot.py")
    check_dir = DEST / "addons" / "gads_editor_check"
    check_dir.mkdir(parents=True)
    shutil.copy2(ROOT / "tests" / "editor_check" / "editor_check_plugin.gd", check_dir / "editor_check_plugin.gd")
    (check_dir / "plugin.cfg").write_text(CHECK_CFG, encoding="utf-8")
    shutil.copy2(ROOT / "tests" / "editor_check" / "build_scene.gd", DEST / "build_scene.gd")
    (DEST / "project.godot").write_text(PROJECT, encoding="utf-8")
    run(["--headless", "--editor", "--quit"])
    run(["--headless", "--import"])
    code, out = run(["--script", "build_scene.gd"])
    if code != 0:
        print("FAIL: could not build the check scene\n" + out[-2000:])
        return 1
    run(["--headless", "--import"])
    code, out = run(["--editor"])
    for line in out.splitlines():
        if line.startswith(("  ok", "  FAIL", "    ")) or "EDITOR CHECK" in line or "SCRIPT ERROR" in line:
            print(line)
    # Messages the check provokes on purpose: the converter reports the material it skips.
    problems = problems_in(out, [r"GADS (info|warning):"])
    for p in problems[:15]:
        print("FAIL (log): " + p)
    if code != 0 or "EDITOR CHECK OK" not in out or problems:
        print(f"FAIL (exit {code})")
        return 1
    print("editor check: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
