#!/usr/bin/env python
"""Run tests/benchmark.gd only on an idle GPU.

The development GPU is shared with other work. A benchmark taken while another process renders
measures that process too, so this waits until, for a whole observation window, `nvidia-smi`
reports low GPU utilisation AND no other rendering engine runs: no Godot process that renders
(Godot started with --headless uses a dummy renderer and does not touch the GPU) and no Unreal
editor. It re-checks right before starting, watches for other engines while the benchmark runs,
and records the GPU state next to the results. It never stops other processes.

    python tools/run_benchmark.py                       # wait up to 2 hours for an idle GPU
    python tools/run_benchmark.py --max-wait 0          # check once, give up if busy
    python tools/run_benchmark.py --allow-idle-unreal   # an open but idle Unreal editor is
                                                        # tolerated (see below)

--allow-idle-unreal: an Unreal editor that is open but not rendering (GPU utilisation at or below
the threshold for the whole, then longer, observation window) does not block the run. The results
file says so. Its viewport could start rendering during the run; the three repeats per row and
their spread are the check for that.

Exit code: the benchmark's (1 = a preset over budget), 3 = the GPU never became idle, 4 = another
rendering engine started during the benchmark (the numbers are not clean; run it again).
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UNREAL = ("unrealeditor", "unrealengine", "ue4editor", "ue5editor")
UNKNOWN = "<process list unavailable>"


def gpu_utilisation() -> int | None:
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=20).stdout
        return max(int(v) for v in out.split() if v.strip().isdigit())
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def _process_list() -> list[tuple[str, str]] | None:
    """(name, command line) of the Godot and Unreal processes (elsewhere: of every process), or
    None when the list cannot be read."""
    try:
        if sys.platform == "win32":
            # Filtered in the query (every process's command line takes over a minute to list on a
            # loaded machine) and returned as JSON (command lines can contain line breaks).
            wql = "Name like 'Godot%' or Name like 'Unreal%' or Name like 'UE4%' or Name like 'UE5%'"
            script = (f'@(Get-CimInstance Win32_Process -Filter "{wql}" | Select-Object Name, CommandLine)'
                      " | ConvertTo-Json -Compress")
            proc = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", script],
                                  capture_output=True, text=True, timeout=90)
            if proc.returncode != 0:
                return None
            text = proc.stdout.strip()
            data = json.loads(text) if text else []
            if isinstance(data, dict):
                data = [data]
            return [(str(d.get("Name") or ""), str(d.get("CommandLine") or "")) for d in data]
        proc = subprocess.run(["ps", "-eo", "comm=,args="], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    if proc.returncode != 0:
        return None
    rows = []
    for line in proc.stdout.splitlines():
        name, _, cmd = line.strip().partition(" ")
        if name:
            rows.append((name, cmd.strip()))
    return rows or None


def rendering_engines() -> list[str]:
    """The Godot processes that render (not --headless) and the Unreal editors, one entry per
    process; [UNKNOWN] when the process list cannot be read (that must count as busy)."""
    rows = _process_list()
    if rows is None:
        return [UNKNOWN]
    out = []
    for name, cmd in rows:
        low = name.lower()
        if "godot" in low and "--headless" not in cmd:
            out.append(name)
        elif any(u in low for u in UNREAL):
            out.append(name)
    return out


def is_unreal(name: str) -> bool:
    return any(u in name.lower() for u in UNREAL)


def idle_for(seconds: int, threshold: int, allow_unreal: bool) -> tuple[bool, str]:
    """True when utilisation stays at or below threshold and no other rendering engine runs for
    [seconds]."""
    samples = []
    tolerated = set()
    for _ in range(max(seconds // 2, 1)):
        engines = rendering_engines()
        blocking = [e for e in engines if not (allow_unreal and is_unreal(e))]
        tolerated.update(e for e in engines if e not in blocking)
        util = gpu_utilisation()
        if blocking:
            return False, f"rendering engines: {', '.join(sorted(set(blocking)))}"
        if util is None:
            return False, "nvidia-smi not available"
        samples.append(util)
        if util > threshold:
            return False, f"GPU utilisation {util} %"
        time.sleep(2)
    note = f"; tolerated while idle: {', '.join(sorted(tolerated))}" if tolerated else ""
    return True, f"GPU utilisation {max(samples)} % max over {seconds} s, no other rendering Godot/Unreal process{note}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--max-wait", type=int, default=7200, help="seconds to wait for an idle GPU")
    parser.add_argument("--window", type=int, default=60, help="seconds the GPU must stay idle")
    parser.add_argument("--threshold", type=int, default=8, help="max utilisation %% counted as idle")
    parser.add_argument("--explore", action="store_true", help="measure candidate field settings (tests/benchmark.gd --explore)")
    parser.add_argument("--allow-idle-unreal", action="store_true",
                        help="an open Unreal editor does not block the run while the GPU stays idle (window x 3)")
    args = parser.parse_args()
    window = args.window * 3 if args.allow_idle_unreal else args.window
    deadline = time.time() + args.max_wait
    while True:
        ok, state = idle_for(window, args.threshold, args.allow_idle_unreal)
        print(f"[run_benchmark] {time.strftime('%H:%M:%S')} {state}", flush=True)
        if ok:
            break
        if time.time() > deadline:
            print("[run_benchmark] GPU not idle; benchmark not run")
            return 3
        time.sleep(30)

    # The benchmark itself is two rendering Godot processes (the console wrapper and the engine);
    # a third one, or an Unreal editor that was not there before, is someone else's work.
    before = rendering_engines()
    unreal_before = sum(1 for e in before if is_unreal(e))
    intruders: set[str] = set()
    unreadable = 0
    done = threading.Event()

    def watch() -> None:
        nonlocal unreadable
        while not done.wait(5):
            engines = rendering_engines()
            if engines == [UNKNOWN]:
                unreadable += 1
                continue
            godots = [e for e in engines if "godot" in e.lower()]
            unreals = [e for e in engines if is_unreal(e)]
            if len(godots) > 2:
                intruders.add(f"{len(godots)} rendering Godot processes")
            if len(unreals) > unreal_before:
                intruders.update(unreals)

    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    proc = subprocess.run([sys.executable, str(ROOT / "tools" / "godot.py"), "--timeout", "3600", "--log", "benchmark",
                           "--script", "tests/benchmark.gd"] + (["--", "--explore"] if args.explore else []), cwd=ROOT)
    done.set()
    watcher.join()
    after_util = gpu_utilisation()
    during = ", ".join(sorted(intruders)) or "none"
    results = ROOT / "build" / ("benchmark_explore.md" if args.explore else "benchmark_results.md")
    if results.exists():
        with results.open("a", encoding="utf-8") as f:
            f.write(f"\nGPU state: before: {state}. During: other rendering engines started: {during}"
                    f"{f' (process list unreadable {unreadable} times)' if unreadable else ''}. "
                    f"After: utilisation {after_util} %.\n")
    if intruders:
        print(f"[run_benchmark] another engine ran during the benchmark ({during}); the numbers are not clean, run it again")
        return 4
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
