#!/usr/bin/env python
"""Run every GADS test suite and scan the engine logs for problems.

    python tests/run_all.py              # import, variants, logic, render, field, bake, terrain, the
                                         # Compatibility and Mobile renderers, visual regression,
                                         # demo and editor smoke, shipped archive, editor plugin,
                                         # Blender bake
    python tests/run_all.py --bench      # ... plus the 1080p preset benchmark (waits for an idle GPU)
    python tests/run_all.py --mutations  # ... plus tests/run_mutations.py (slow)

Render suites open a window: --headless is a dummy renderer that draws nothing. A suite fails
if its exit code is non-zero OR its log contains script errors, engine errors (other than the
audio-device noise of a machine without speakers) or leak reports at exit ("RID ... was
leaked", "ObjectDB instance ... leaked", "resources still in use").
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "tools" / "godot.py"
BLENDER = os.environ.get("BLENDER_BIN", "E:/tools/blender-4.5.9-windows-x64/blender.exe")

from log_scan import problems_in  # noqa: E402  (tests/ is on sys.path when run directly)

SUITES = [
    ("import", ["--headless", "--import"], None),
    ("logic tests", ["--headless", "--script", "tests/run_logic_tests.gd"], r"logic tests: (\d+) passed, (\d+) failed"),
    ("render tests", ["--script", "tests/render_tests.gd"], r"render tests: (\d+) passed, (\d+) failed"),
    ("field tests", ["--script", "tests/field_tests.gd"], r"field tests: (\d+) passed, (\d+) failed"),
    ("bake tests", ["--script", "tests/bake_tests.gd"], r"bake tests: (\d+) passed, (\d+) failed"),
    ("terrain tests", ["--script", "tests/terrain_tests.gd"], r"terrain tests: (\d+) passed, (\d+) failed"),
    ("Compatibility renderer", ["--rendering-method", "gl_compatibility", "--script", "tests/renderer_tests.gd"],
     r"renderer tests \(gl_compatibility\): (\d+) passed, (\d+) failed"),
    ("Mobile renderer", ["--rendering-method", "mobile", "--script", "tests/renderer_tests.gd"],
     r"renderer tests \(mobile\): (\d+) passed, (\d+) failed"),
    ("visual regression", ["--fixed-fps", "30", "--script", "tests/visual_regression.gd"],
     r"visual regression: (\d+) passed, (\d+) failed"),
    ("demo smoke", ["res://demo/demo_main.tscn", "--quit-after", "400"], None),
    ("editor smoke", ["--editor", "res://demo/demo_main.tscn", "--quit-after", "300"], None),
]


def run_suite(name: str, args: list[str], summary: str | None) -> tuple[bool, str]:
    log_name = "test_" + re.sub(r"\W+", "_", name)
    proc = subprocess.run(
        [sys.executable, str(RUNNER), "--timeout", "1800", "--log", log_name] + args,
        cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    out = proc.stdout + proc.stderr
    problems = problems_in(out)
    detail = ""
    if summary:
        m = re.search(summary, out)
        detail = m.group(0) if m else "no summary line found"
        if not m:
            problems.append(detail)
    ok = proc.returncode == 0 and not problems
    report = f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else "")
    report += f"  exit={proc.returncode}"
    for p in problems[:15]:
        report += f"\n        {p}"
    for line in out.splitlines():
        if line.strip().startswith("FAIL"):
            report += f"\n        {line.strip()}"
    return ok, report


def run_python_check(name: str, args: list[str]) -> tuple[bool, str]:
    proc = subprocess.run([sys.executable] + args, cwd=ROOT, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    ok = proc.returncode == 0
    lines = proc.stdout.strip().splitlines() or ["no output"]
    report = f"{'PASS' if ok else 'FAIL'}  {name}  ({lines[-1]})  exit={proc.returncode}"
    if not ok:
        for line in lines[-15:]:
            report += "\n        " + line
    return ok, report


def main() -> int:
    results = []
    ok, report = run_python_check("shader variants up to date", ["tools/generate_variants.py", "--check"])
    print(report, flush=True)
    results.append(ok)
    for name, args, summary in SUITES:
        ok, report = run_suite(name, args, summary)
        print(report, flush=True)
        results.append(ok)
    checks = [
        ("standalone addon (shipped archive)", ["tests/run_standalone_check.py"]),
        ("editor plugin tools + undo/redo", ["tests/run_editor_check.py"]),
    ]
    if shutil.which(BLENDER) or Path(BLENDER).exists():
        checks.append(("offline Blender bake", ["tests/test_blender_bake.py", "--blender", BLENDER]))
    if "--bench" in sys.argv:
        checks.append(("benchmark (idle GPU)", ["tools/run_benchmark.py"]))
    if "--mutations" in sys.argv:
        checks.append(("mutation checks", ["tests/run_mutations.py"]))
    for name, args in checks:
        ok, report = run_python_check(name, args)
        print(report, flush=True)
        results.append(ok)
    passed = sum(results)
    print(f"\n{passed}/{len(results)} suites passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
