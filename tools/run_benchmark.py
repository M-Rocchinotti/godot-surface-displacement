#!/usr/bin/env python
"""Run tests/benchmark.gd only on an idle GPU.

The development GPU is shared with other work. A benchmark taken while another process renders
measures that process too, so this waits until, for a whole observation window, `nvidia-smi`
reports low GPU utilisation AND no other Godot or Unreal process runs; it re-checks right
before starting, watches for other engines while the benchmark runs, and records the GPU state
next to the results. It never stops other processes.

    python tools/run_benchmark.py                 # wait up to 2 hours for an idle GPU
    python tools/run_benchmark.py --max-wait 0    # check once, give up if busy

Exit code: the benchmark's (1 = a preset over budget), 3 = the GPU never became idle, 4 = another
Godot or Unreal process ran during the benchmark (the numbers are not clean; run it again).
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUSY_PROCESSES = ("godot", "unrealeditor", "unrealengine", "ue4editor", "ue5editor")


def gpu_utilisation() -> int | None:
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=20).stdout
        return max(int(v) for v in out.split() if v.strip().isdigit())
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


UNKNOWN = "<process list unavailable>"


def engine_processes() -> list[str]:
    """Names of the running Godot / Unreal processes, one entry per process. When the process
    list cannot be read, [UNKNOWN]: an unreadable list must count as busy, never as idle."""
    try:
        if sys.platform == "win32":
            proc = subprocess.run(["tasklist", "/fo", "csv", "/nh"], capture_output=True, text=True, timeout=60)
            names = [line.split('","')[0].strip('"') for line in proc.stdout.splitlines() if line.startswith('"')]
        else:
            proc = subprocess.run(["ps", "-eo", "comm"], capture_output=True, text=True, timeout=60)
            names = proc.stdout.split()
    except (OSError, subprocess.SubprocessError):
        return [UNKNOWN]
    if proc.returncode != 0 or not names:
        return [UNKNOWN]
    return [n for n in names if any(b in n.lower() for b in BUSY_PROCESSES)]


def busy_processes() -> list[str]:
    """Names of the running Godot / Unreal processes, each once."""
    return sorted(set(engine_processes()))


def idle_for(seconds: int, threshold: int) -> tuple[bool, str]:
    """True when utilisation stays at or below threshold and no busy process runs for [seconds]."""
    samples = []
    for _ in range(max(seconds // 2, 1)):
        procs = busy_processes()
        util = gpu_utilisation()
        if procs:
            return False, f"busy processes: {', '.join(procs)}"
        if util is None:
            return False, "nvidia-smi not available"
        samples.append(util)
        if util > threshold:
            return False, f"GPU utilisation {util} %"
        time.sleep(2)
    return True, f"GPU utilisation {max(samples)} % max over {seconds} s, no other Godot/Unreal process"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--max-wait", type=int, default=7200, help="seconds to wait for an idle GPU")
    parser.add_argument("--window", type=int, default=60, help="seconds the GPU must stay idle")
    parser.add_argument("--threshold", type=int, default=8, help="max utilisation %% counted as idle")
    args = parser.parse_args()
    deadline = time.time() + args.max_wait
    while True:
        ok, state = idle_for(args.window, args.threshold)
        print(f"[run_benchmark] {time.strftime('%H:%M:%S')} {state}", flush=True)
        if ok:
            break
        if time.time() > deadline:
            print("[run_benchmark] GPU not idle; benchmark not run")
            return 3
        time.sleep(30)

    # The benchmark itself is at most two Godot processes (the console wrapper and the engine);
    # a third Godot or any Unreal process while it runs is someone else's work on the GPU.
    intruders: set[str] = set()
    done = threading.Event()

    def watch() -> None:
        while not done.wait(5):
            procs = engine_processes()
            godots = [n for n in procs if "godot" in n.lower()]
            others = [n for n in procs if "godot" not in n.lower() and n != UNKNOWN]
            if len(godots) > 2:
                intruders.add(f"{len(godots)} Godot processes")
            intruders.update(others)

    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    proc = subprocess.run([sys.executable, str(ROOT / "tools" / "godot.py"), "--timeout", "3600", "--log", "benchmark",
                           "--script", "tests/benchmark.gd"], cwd=ROOT)
    done.set()
    watcher.join()
    after_util = gpu_utilisation()
    after_procs = busy_processes()
    during = ", ".join(sorted(intruders)) or "none"
    results = ROOT / "build" / "benchmark_results.md"
    if results.exists():
        with results.open("a", encoding="utf-8") as f:
            f.write(f"\nGPU state: before: {state}; during: other Godot/Unreal processes: {during}; "
                    f"after: utilisation {after_util} %, other Godot/Unreal processes: {', '.join(after_procs) or 'none'}.\n")
    if intruders:
        print(f"[run_benchmark] another engine ran during the benchmark ({during}); the numbers are not clean, run it again")
        return 4
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
