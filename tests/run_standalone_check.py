#!/usr/bin/env python
"""Check that the addon works exactly as users download it, alone in a new project.

Builds build/standalone/ from `git archive` of the working copy (see shipped_archive.py: what
the Asset Library serves, .uid and .import files included, demo/tests/docs excluded), checks
that the archive holds nothing else and no dangling links, adds a minimal Forward+
project.godot that only enables the plugin, lets the editor import it (the plugin registers the
shader globals on first run), then runs tests/standalone_check.gd there (headed). Fails on engine
errors or leak reports in the logs. Exit code 0 = the addon works.

    python tests/run_standalone_check.py
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

from log_scan import problems_in
import shipped_archive

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / "build" / "standalone"
GLOBALS = ["sd_pom_steps", "sd_pom_range", "sd_shadow", "sd_debug", "sd_dfg"]

PROJECT = """config_version=5

[application]

config/name="Surface Displacement standalone check"
config/features=PackedStringArray("4.7", "Forward Plus")

[editor_plugins]

enabled=PackedStringArray("res://addons/surface_displacement/plugin.cfg")
"""


def run(args: list[str]) -> tuple[int, str]:
    proc = subprocess.run([sys.executable, str(DEST / "tools" / "godot.py"), "--timeout", "300"] + args,
                          cwd=DEST, capture_output=True, text=True, encoding="utf-8", errors="replace")
    return proc.returncode, proc.stdout + proc.stderr


def main() -> int:
    if DEST.exists():
        shutil.rmtree(DEST)
    DEST.mkdir(parents=True)
    names = shipped_archive.extract(DEST)
    issues = shipped_archive.problems(names, DEST)
    for issue in issues:
        print("FAIL: " + issue)
    if issues:
        return 1
    print(f"archive: {len(names)} entries, only LICENSE and addons/surface_displacement")
    (DEST / "tools").mkdir()
    shutil.copy2(ROOT / "tools" / "godot.py", DEST / "tools" / "godot.py")
    if (ROOT / "tools" / ".godot_path").exists():
        shutil.copy2(ROOT / "tools" / ".godot_path", DEST / "tools" / ".godot_path")
    shutil.copy2(ROOT / "tests" / "standalone_check.gd", DEST / "check.gd")
    (DEST / "project.godot").write_text(PROJECT, encoding="utf-8")
    # First run imports and lets the plugin register the shader globals; the second must be clean.
    run(["--headless", "--editor", "--quit"])
    code, out = run(["--headless", "--import"])
    problems = problems_in(out)
    project_text = (DEST / "project.godot").read_text(encoding="utf-8")
    missing = [g for g in GLOBALS if f"{g}=" not in project_text]
    if "[shader_globals]" not in project_text or missing:
        print(f"FAIL: the plugin did not register the shader globals {missing}")
        return 1
    code, out = run(["--script", "check.gd"])
    problems += problems_in(out)
    for line in out.splitlines():
        if "STANDALONE" in line or line.startswith("  "):
            print(line)
    for p in problems[:15]:
        print("FAIL (log): " + p)
    if code != 0 or "STANDALONE OK" not in out or problems:
        print(f"FAIL (exit {code})")
        return 1
    print("standalone addon check: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
