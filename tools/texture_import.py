"""Write Godot `.import` files with explicit settings for GADS textures.

Godot decides import settings on first import. Without an explicit `.import`, a texture used only
by a ShaderMaterial is imported as a 2D texture WITHOUT mipmaps (the bug that made the crater's
POM shimmer), and "Detect 3D" may later recompress a height map to lossy BC6H. Writing the
`.import` file before the first import pins the settings; Godot fills in the remaining keys.

Kinds:
    color   VRAM compressed (BC1/BC3), mipmaps
    normal  VRAM compressed as a normal map (BC5 / RGTC), mipmaps
    linear  VRAM compressed, mipmaps (ORM / "arm" packs; sampled without sRGB)
    height  lossless: HDR images (EXR) stay uncompressed half floats, mipmaps
    lut     lossless, no mipmaps (look-up tables read with texelFetch)
"""
from __future__ import annotations

from pathlib import Path

_BASE = {
    "compress/mode": 2,
    "compress/high_quality": "false",
    "compress/lossy_quality": 0.7,
    "compress/hdr_compression": 1,
    "compress/normal_map": 0,
    "compress/channel_pack": 0,
    "mipmaps/generate": "true",
    "mipmaps/limit": -1,
    "roughness/mode": 0,
    "roughness/src_normal": '""',
    "process/fix_alpha_border": "true",
    "process/premult_alpha": "false",
    "process/normal_map_invert_y": "false",
    "process/hdr_as_srgb": "false",
    "process/hdr_clamp_exposure": "false",
    "process/size_limit": 0,
    "detect_3d/compress_to": 0,
}

KINDS = {
    "color": {},
    "normal": {"compress/normal_map": 1},
    "linear": {},
    "height": {"compress/mode": 0},
    "lut": {"compress/mode": 0, "mipmaps/generate": "false"},
}


def import_text(kind: str) -> str:
    params = dict(_BASE)
    params.update(KINDS[kind])
    lines = ["[remap]", "", 'importer="texture"', 'type="CompressedTexture2D"', "", "[params]", ""]
    lines += [f"{k}={v}" for k, v in params.items()]
    return "\n".join(lines) + "\n"


def write_import(texture: Path, kind: str) -> Path:
    """Writes `<texture>.import` for [kind]. An existing file is replaced only if its [params]
    differ, so Godot keeps its uid and cache paths when nothing changed."""
    path = Path(str(texture) + ".import")
    wanted = import_text(kind)
    if path.exists():
        current = path.read_text(encoding="utf-8")
        params = current.split("[params]", 1)[-1]
        if all(line in params.splitlines() for line in wanted.split("[params]", 1)[1].strip().splitlines()):
            return path
    path.write_text(wanted, encoding="utf-8", newline="\n")
    return path


if __name__ == "__main__":
    import sys
    if len(sys.argv) != 3 or sys.argv[2] not in KINDS:
        print(f"usage: python tools/texture_import.py <texture> <{'|'.join(KINDS)}>")
        sys.exit(2)
    print(write_import(Path(sys.argv[1]), sys.argv[2]))
