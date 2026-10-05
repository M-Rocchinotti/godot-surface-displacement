#!/usr/bin/env python
"""Render and encode the showcase videos (build/videos/*.mp4; not committed, 66 MB).

    python tools/make_videos.py                 # render all frames (tools/capture_videos.gd), encode, check
    python tools/make_videos.py --encode-only   # encode and check frames rendered before

Each clip is rendered frame by frame at 30 fps real-time camera speed (never sped up) and encoded
as H.264 (yuv420p, CRF 20). The two comparison videos put the flat (normal mapping only) and the
full displacement render of the same camera move side by side, labelled. Checks on every clip:
no black frames, no pops (a frame differing from its predecessor far more than the clip's typical
frame-to-frame change), the expected frame count and duration. Needs ffmpeg and ffprobe on PATH.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
FRAMES = ROOT / "build" / "video_frames"
OUT = ROOT / "build" / "videos"
FPS = 30
FONT = "fontfile='C\\:/Windows/Fonts/segoeuib.ttf'" if sys.platform == "win32" else "font=Sans"

SINGLE = {
    "gravel_path_walk": "Gravel path, eye-level walk (Ultra: POM, self-shadowing, near-camera geometry, pebbles)",
    "gravel_path_grazing": "Gravel path, low sweep across the path (Ultra)",
    "cobblestone_street_walk": "Cobblestone street, eye-level walk (Ultra)",
    "cobblestone_street_grazing": "Cobblestone street, low sweep (Ultra)",
    "brick_wall_walk": "Brick wall and props, walk along the wall (Ultra; left box parallax only, right wall baked geometry)",
}
COMPARE = {
    "compare_gravel_path_grazing": "Gravel path, low sweep: flat normal mapping (left) vs full displacement (right)",
    "compare_cobblestone_street_grazing": "Cobblestone street, low sweep: flat normal mapping (left) vs full displacement (right)",
}


def run(cmd: list[str]) -> None:
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if proc.returncode != 0:
        raise SystemExit(f"failed: {' '.join(cmd[:4])} ...\n{proc.stderr[-2000:]}")


def encode_single(name: str) -> Path:
    out = OUT / f"{name}.mp4"
    run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", str(FRAMES / name / "%05d.jpg"),
         "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(out)])
    return out


def encode_compare(name: str) -> Path:
    out = OUT / f"{name}.mp4"
    label = ("drawtext=" + FONT + ":text='{}':x=32:y=28:fontsize=40:fontcolor=white"
             ":box=1:boxcolor=black@0.45:boxborderw=14")
    graph = (f"[0:v]{label.format('Flat (normal mapping)')}[a];"
             f"[1:v]{label.format('Displacement (POM + geometry + pebbles)')}[b];"
             "[a][b]hstack=inputs=2[v]")
    run(["ffmpeg", "-y", "-loglevel", "error",
         "-framerate", str(FPS), "-i", str(FRAMES / f"{name}_flat" / "%05d.jpg"),
         "-framerate", str(FPS), "-i", str(FRAMES / f"{name}_full" / "%05d.jpg"),
         "-filter_complex", graph, "-map", "[v]",
         "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(out)])
    return out


def probe(path: Path) -> dict:
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
                          "-show_entries", "stream=width,height,r_frame_rate,nb_read_frames,codec_name:format=duration,size",
                          "-of", "json", str(path)], capture_output=True, text=True).stdout
    data = json.loads(out)
    return {**data["streams"][0], **data["format"]}


def check_frames(dirs: list[Path]) -> list[str]:
    """Problems in the rendered frames: black frames and pops."""
    problems = []
    for d in dirs:
        files = sorted(d.glob("*.jpg"))
        prev = None
        lums = []
        diffs = []
        for f in files:
            a = np.asarray(Image.open(f).convert("L").resize((320, 180)), dtype=np.float32) / 255.0
            lums.append(float(a.mean()))
            if prev is not None:
                diffs.append(float(np.abs(a - prev).mean()))
            prev = a
        if not files:
            problems.append(f"{d.name}: no frames")
            continue
        dark = [i for i, v in enumerate(lums) if v < 0.05]
        if dark:
            problems.append(f"{d.name}: {len(dark)} black frames (first {dark[0]})")
        if diffs:
            median = float(np.median(diffs))
            pops = [i + 1 for i, v in enumerate(diffs) if v > max(4.0 * median, 0.01)]
            if pops:
                problems.append(f"{d.name}: {len(pops)} frames change far more than usual (first {pops[0]}, "
                                f"{max(diffs):.4f} vs median {median:.4f})")
        print(f"  {d.name}: {len(files)} frames, luminance {min(lums):.2f}-{max(lums):.2f}, "
              f"frame-to-frame change median {np.median(diffs) if diffs else 0:.4f}, largest {max(diffs) if diffs else 0:.4f}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--encode-only", action="store_true")
    args = parser.parse_args()
    if not args.encode_only:
        run([sys.executable, str(ROOT / "tools" / "godot.py"), "--timeout", "3600", "--log", "videos",
             "--script", "tools/capture_videos.gd"])
    OUT.mkdir(parents=True, exist_ok=True)
    frame_dirs = [FRAMES / n for n in SINGLE] + [FRAMES / f"{n}_{m}" for n in COMPARE for m in ("flat", "full")]
    problems = check_frames(frame_dirs)
    videos = [encode_single(n) for n in SINGLE] + [encode_compare(n) for n in COMPARE]
    for v in videos:
        info = probe(v)
        frames = int(info["nb_read_frames"])
        print(f"  {v.relative_to(ROOT)}: {info['width']}x{info['height']} {info['codec_name']} {info['r_frame_rate']} fps, "
              f"{frames} frames, {float(info['duration']):.2f} s, {int(info['size']) / 1e6:.1f} MB")
        if info["r_frame_rate"] != f"{FPS}/1" or frames != 7 * FPS:
            problems.append(f"{v.name}: {frames} frames at {info['r_frame_rate']}")
    for p in problems:
        print("PROBLEM", p)
    print("videos: OK" if not problems else f"videos: {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
