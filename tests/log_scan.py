"""What counts as a problem in a Godot log, shared by every test runner.

A run fails if its output contains script errors, engine errors (other than the audio-device
noise of a machine without speakers or sound card) or leak reports at exit ("RID ... was leaked",
"ObjectDB instance ... leaked", "resources still in use").
"""
from __future__ import annotations

import re

# Lines that are environment noise on the development machine, not project problems.
IGNORED = [
    re.compile(r"WASAPI|audio_driver_wasapi|All audio drivers failed|audio_server\.cpp"),
    re.compile(r'Condition "hr != \(\(HRESULT\)0x00000000\)" is true'),
    re.compile(r"Failed to request display timeout override"),
    re.compile(r"Message Id Name: Loader Message"),
]
PROBLEMS = [
    re.compile(r"SCRIPT ERROR"),
    re.compile(r"^ERROR:"),
    re.compile(r"was leaked|were leaked|leaked at exit", re.IGNORECASE),
    re.compile(r"resources still in use", re.IGNORECASE),
    re.compile(r"^WARNING:.*(surface_displacement|Surface Displacement|SurfaceDisplacement|SDGlobals|DisplacementField3D|PebbleScatter3D)"),
    re.compile(r"SHADER ERROR"),
]


# An engine error is reported on one line and located on the next ("   at: function (file:line)");
# errors located in an audio driver are the same noise (Linux without a sound card: ALSA).
AUDIO_LOCATION = re.compile(r"^\s*at: .*\((drivers/(alsa|pulseaudio|wasapi|coreaudio)/|servers/audio/)")


def problems_in(output: str, expected: list[str] | None = None) -> list[str]:
    """The problem lines of a Godot run's combined stdout/stderr. [expected] are regexes of
    warnings the run provokes on purpose (they are still printed by the caller's tests)."""
    allowed = [re.compile(e) for e in (expected or [])]
    found = []
    lines = output.splitlines()
    for i, line in enumerate(lines):
        if any(p.search(line) for p in IGNORED) or any(a.search(line) for a in allowed):
            continue
        if i + 1 < len(lines) and AUDIO_LOCATION.search(lines[i + 1]):
            continue
        if any(p.search(line) for p in PROBLEMS):
            found.append(line.strip())
    return found
