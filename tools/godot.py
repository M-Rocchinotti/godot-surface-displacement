#!/usr/bin/env python
"""Run Godot (4.7 or later) against this project under a cross-process lock.

Two Godot processes importing or editing the same `.godot/` cache at once corrupt it,
so every engine invocation goes through this wrapper, which serialises them with a
lock file in `build/`.

Which engine: the GODOT_BIN (or SURFACE_DISPLACEMENT_GODOT) environment variable, else the path in
tools/.godot_path (one line; git-ignored, for a machine-local setup), else `godot`, `godot4`
or an official Godot binary name found on PATH. Nothing machine-specific is hard-coded.

Usage (from anywhere):
    python tools/godot.py --headless --import
    python tools/godot.py --headless --script tests/run_logic_tests.gd
    python tools/godot.py res://demo/demo_main.tscn --quit-after 300
    python tools/godot.py --script tests/render_tests.gd   (headed: --headless is a dummy renderer)

Options handled here (not passed to Godot):
    --timeout N     kill the engine after N seconds (default 900)
    --log NAME      write output to build/logs/NAME.log (default: timestamped)

Exit code is Godot's exit code (124 on timeout, 125 if the lock could not be taken).
"""
from __future__ import annotations

import os
import subprocess
import sys
import threading
import time
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent


GODOT_NAMES = ["godot", "godot4", "Godot_v4.7.2-stable_win64_console.exe", "Godot_v4.7.2-stable_win64.exe",
               "Godot_v4.7.2-stable_linux.x86_64"]


def _find_godot() -> Path | None:
    """The engine binary for THIS machine, or None (see the module docstring for the order).

    On Windows prefer the *_console.exe build: the plain one detaches from the console and
    this wrapper needs the child's stdout to log it.
    """
    from shutil import which

    for var in ("GODOT_BIN", "SURFACE_DISPLACEMENT_GODOT"):
        value = os.environ.get(var, "").strip()
        if value:
            return Path(value)
    local = Path(__file__).with_name(".godot_path")
    if local.exists():
        value = local.read_text(encoding="utf-8").strip()
        if value:
            return Path(value)
    for name in GODOT_NAMES:
        found = which(name)
        if found:
            return Path(found)
    return None


GODOT = _find_godot()
LOCK = PROJECT / "build" / ".godot.lock"
LOG_DIR = PROJECT / "build" / "logs"
LOCK_WAIT = 3600        # seconds to wait for another process to finish
STALE_AFTER = 1500      # a lock older than this is assumed dead (runs are capped at 900 s)


def holder_alive(pid: int) -> bool:
    """Is the process that wrote the lock still running?

    WHY THIS EXISTS. The age check below is the only thing that ever freed a lock, and a
    holder that dies without releasing -- killed, crashed, or a parent that took its child
    down with it -- therefore blocks every other run for the full STALE_AFTER. That is not
    theoretical: eight agents and a test suite sat idle for twenty minutes behind a lock
    whose PID had already been killed, with no Godot process running anywhere on the
    machine. A dead holder is knowable immediately, so it should be.

    UNKNOWN COUNTS AS ALIVE, deliberately. A PID can be recycled, the lock can be read in
    the instant between its creation and its first write, and a query can be refused. Every
    one of those returns True and leaves the age check to do its job -- refusing to break a
    lock that might be held is a delay, breaking one that IS held is two engines writing
    into the same .godot/ directory.

    NOT os.kill(pid, 0). On Windows CPython's os.kill does not probe: for any signal other
    than CTRL_C_EVENT/CTRL_BREAK_EVENT it calls TerminateProcess with the signal number as
    the exit code, so the "check" would kill the very run it was asking about.
    """
    if pid <= 0:
        return True
    if os.name == "nt":
        import ctypes
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        STILL_ACTIVE = 259
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not handle:
            # No handle means no such process -- or no permission to ask, which cannot
            # happen for a sibling run of this script under the same user.
            return False
        try:
            code = ctypes.c_ulong()
            if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
                return True
            # A handle can outlive the process it names; STILL_ACTIVE is what separates the
            # two. A live process that genuinely exits with 259 reads as alive here and is
            # covered by the age check.
            return code.value == STILL_ACTIVE
        finally:
            kernel32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def lock_holder() -> int:
    """The PID in the lock file, or 0 if it cannot be read.

    0 is the "do not decide" answer: the file is created empty and written a moment later,
    so an unparseable lock is usually a lock half a millisecond old, not a corrupt one.
    """
    try:
        first = LOCK.read_text(encoding="utf-8").split()
        return int(first[0]) if first else 0
    except (OSError, ValueError):
        return 0


def acquire_lock() -> bool:
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    # build/ holds logs and test captures; keep Godot from importing them as assets.
    (LOCK.parent / ".gdignore").touch(exist_ok=True)
    deadline = time.time() + LOCK_WAIT
    while True:
        try:
            fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, f"{os.getpid()} {time.time():.0f}\n".encode())
            os.close(fd)
            return True
        except FileExistsError:
            try:
                age = time.time() - LOCK.stat().st_mtime
                pid = lock_holder()
                # The holder being gone is a fact; the age is only a guess about it. Ask
                # first, and do not wait out STALE_AFTER for a process that has already
                # exited. A lock younger than a second is left alone either way: it may
                # have been created but not yet written, and lock_holder() cannot tell
                # that apart from a corrupt file.
                if age > 1.0 and pid and not holder_alive(pid):
                    print(f"[godot.py] breaking lock of dead pid {pid} ({age:.0f}s old)",
                          file=sys.stderr)
                    LOCK.unlink()
                    continue
                if age > STALE_AFTER:
                    print(f"[godot.py] breaking stale lock ({age:.0f}s old)", file=sys.stderr)
                    LOCK.unlink()
                    continue
            except FileNotFoundError:
                continue
            if time.time() > deadline:
                print("[godot.py] could not acquire the engine lock", file=sys.stderr)
                return False
            time.sleep(2)


def release_lock() -> None:
    try:
        LOCK.unlink()
    except FileNotFoundError:
        pass


def kill_tree(pid: int) -> None:
    """Kill the engine and everything it started.

    On Windows the console exe starts the real Godot binary as a child; plain kill() on the
    launcher leaves the engine running as an orphan that keeps rendering, logging and
    holding files open. Elsewhere the engine runs in its own process group."""
    if os.name == "nt":
        subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        import signal
        try:
            os.killpg(os.getpgid(pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass


def main(argv: list[str]) -> int:
    timeout = 900
    log_name = None
    passthrough: list[str] = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--timeout" and i + 1 < len(argv):
            timeout = int(argv[i + 1]); i += 2; continue
        if a == "--log" and i + 1 < len(argv):
            log_name = argv[i + 1]; i += 2; continue
        passthrough.append(a); i += 1

    if GODOT is None or not GODOT.exists():
        where = f"at {GODOT}" if GODOT is not None else "(GODOT_BIN not set, no tools/.godot_path, nothing on PATH)"
        print(f"[godot.py] Godot engine not found {where}.", file=sys.stderr)
        print("[godot.py] Set GODOT_BIN to the Godot 4.7+ editor executable (on Windows the *_console.exe),",
              file=sys.stderr)
        print("[godot.py] or write its path into tools/.godot_path, or put `godot` on PATH.", file=sys.stderr)
        return 2
    if not acquire_lock():
        return 125

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    log_path = LOG_DIR / f"{log_name or stamp}.log"
    cmd = [str(GODOT), "--path", str(PROJECT)] + passthrough
    print(f"[godot.py] {' '.join(cmd)}")
    started = time.time()
    timed_out = threading.Event()
    try:
        with open(log_path, "w", encoding="utf-8", errors="replace") as log:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    cwd=str(PROJECT), text=True, encoding="utf-8", errors="replace",
                                    start_new_session=os.name != "nt")

            # A silent hang (no output at all) must still die: watchdog thread, not a
            # check inside the read loop, because readline blocks without output.
            def watchdog() -> None:
                if not proc_done.wait(timeout):
                    timed_out.set()
                    kill_tree(proc.pid)

            proc_done = threading.Event()
            threading.Thread(target=watchdog, daemon=True).start()
            for line in proc.stdout:
                sys.stdout.write(line)
                log.write(line)
                log.flush()
            proc.wait()
            proc_done.set()
        if timed_out.is_set():
            print(f"[godot.py] timeout after {timeout}s (killed)", file=sys.stderr)
            return 124
        print(f"[godot.py] exit {proc.returncode} in {time.time() - started:.1f}s (log: {log_path})")
        return proc.returncode
    finally:
        release_lock()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
