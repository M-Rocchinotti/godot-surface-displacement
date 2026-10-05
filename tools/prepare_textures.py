#!/usr/bin/env python
"""Turn downloaded Poly Haven sets into the demo's texture copies (demo/textures/<id>/).

Input: the cache written by tools/fetch_textures.py (default E:/dev-cache/polyhaven-hq, or the
GADS_TEXTURE_CACHE environment variable, or --cache). Per set it writes:

    <id>_height.exr   16-bit float height, single "R" channel, remapped so the 1st/99th
                      percentiles of the source map become 0/1 (robust against outliers), from the
                      source EXR (ZIP) or, where Poly Haven's EXR uses DWAA, its 16-bit PNG
    <id>_albedo.jpg, <id>_normal.jpg, <id>_arm.jpg   resized colour maps (normal: OpenGL, arm:
                      AO / roughness / metallic)
    *.import          explicit import settings (tools/texture_import.py): mipmaps everywhere,
                      lossless half-float height, BC5 normal map
    <id>.license.json the Poly Haven CC0 record, copied
    <id>.gads.json      real-world size (m), suggested relief depth (m), source percentiles

    python tools/prepare_textures.py                 # the demo sets at the demo resolutions
    python tools/prepare_textures.py --res 2048 gravel_stones rocks_ground_02
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from exr import read_exr, write_exr  # noqa: E402
from png16 import read_png16  # noqa: E402
from texture_import import write_import  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CACHE = Path(os.environ.get("GADS_TEXTURE_CACHE", "E:/dev-cache/polyhaven-hq"))
DEFAULT_OUT = ROOT / "demo" / "textures"

# id -> (demo resolution in px, suggested relief depth in metres). The depths are judgement calls
# from the stone sizes in the photos (gravel 1-4 cm, setts ~5 cm, rocks up to ~20 cm).
DEMO_SETS = {
    "gravel_stones": (1024, 0.03),
    "rocky_gravel": (1024, 0.035),
    "clean_pebbles": (2048, 0.025),
    "cobblestone_floor_08": (1024, 0.05),
    "square_cobblestone": (1024, 0.04),
    "rocks_ground_05": (1024, 0.18),
    "brick_wall_001": (1024, 0.025),
    "rubble": (1024, 0.08),
    "forest_ground_04": (1024, 0.02),
}


def load_height(cache: Path, entry: dict) -> np.ndarray:
    maps = entry["maps"]
    if entry.get("height_source") == "exr":
        channels = read_exr(cache / maps["height_exr"]["path"])
        return channels.get("Y", channels.get("R", next(iter(channels.values()))))
    return read_png16(cache / maps["height_png16"]["path"])


def box_downsample(img: np.ndarray, size: int) -> np.ndarray:
    """Area average by an integer factor (the source maps are square powers of two)."""
    factor = img.shape[0] // size
    if factor <= 1:
        return img
    h, w = img.shape
    return img.reshape(h // factor, factor, w // factor, factor).mean(axis=(1, 3))


def resize_jpg(src: Path, dst: Path, size: int) -> None:
    with Image.open(src) as im:
        im = im.convert("RGB")
        if im.size != (size, size):
            im = im.resize((size, size), Image.LANCZOS)
        im.save(dst, "JPEG", quality=92, subsampling=0)


def prepare(cache: Path, out_root: Path, set_id: str, entry: dict, res: int, height_m: float) -> dict:
    out = out_root / set_id
    out.mkdir(parents=True, exist_ok=True)
    height = load_height(cache, entry).astype(np.float64)
    p1, p99 = np.percentile(height, [1.0, 99.0])
    remapped = np.clip((height - p1) / max(p99 - p1, 1e-6), 0.0, 1.0)
    remapped = box_downsample(remapped, res)
    height_path = out / f"{set_id}_height.exr"
    write_exr(height_path, {"R": remapped.astype(np.float32)}, half=True, compression="zip")
    write_import(height_path, "height")
    for key, suffix, kind in (("albedo", "albedo", "color"), ("normal_gl", "normal", "normal"), ("arm", "arm", "linear")):
        dst = out / f"{set_id}_{suffix}.jpg"
        resize_jpg(cache / entry["maps"][key]["path"], dst, res)
        write_import(dst, kind)
    shutil.copy2(cache / entry["license_file"], out / f"{set_id}.license.json")
    meta = {
        "id": set_id,
        "size_m": entry["size_m"],
        "height_m": height_m,
        "resolution": res,
        "height_source": entry.get("height_source"),
        "source_percentiles": [round(float(p1), 6), round(float(p99), 6)],
        "height_remap_applied": True,
        "license": "CC0-1.0",
        "source": f"https://polyhaven.com/a/{set_id}",
    }
    (out / f"{set_id}.gads.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8", newline="\n")
    return meta


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ids", nargs="*", help="Poly Haven ids (default: the demo sets)")
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--res", type=int, default=0, help="output size in px (default: per-set demo size)")
    args = parser.parse_args()
    manifest = json.loads((args.cache / "manifest.json").read_text(encoding="utf-8"))["sets"]
    ids = args.ids or list(DEMO_SETS)
    for set_id in ids:
        if set_id not in manifest:
            print(f"{set_id}: not in {args.cache / 'manifest.json'} (run tools/fetch_textures.py {set_id})")
            return 1
        res, height_m = DEMO_SETS.get(set_id, (1024, 0.03))
        meta = prepare(args.cache, args.out, set_id, manifest[set_id], args.res or res, height_m)
        print(f"{set_id}: {meta['resolution']} px, {meta['size_m'][0]} m tile, height from {meta['height_source']}, "
              f"source p1/p99 {meta['source_percentiles']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
