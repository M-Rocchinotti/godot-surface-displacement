"""Read a 16-bit greyscale PNG (colour type 0 or 4) at full precision.

Pillow opens 16-bit grey+alpha PNGs as 8-bit RGBA and Godot converts 16-bit PNGs to 8 bit on
import, so the height maps that Poly Haven ships only as 16-bit PNG (their EXR uses DWAA, which
Godot cannot read) are decoded here: inflate, then undo the per-row filters (PNG spec 9.2).

    from png16 import read_png16
    grey = read_png16("height.png")   # float32 array (h, w) in [0, 1]
"""
from __future__ import annotations

import struct
import zlib
from pathlib import Path

import numpy as np

SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _paeth_row(filt: bytes, prior: bytearray, bpp: int) -> bytearray:
    out = bytearray(filt)
    for i in range(len(out)):
        a = out[i - bpp] if i >= bpp else 0
        b = prior[i]
        c = prior[i - bpp] if i >= bpp else 0
        p = a + b - c
        pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
        pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
        out[i] = (out[i] + pred) & 0xFF
    return out


def _average_row(filt: bytes, prior: bytearray, bpp: int) -> bytearray:
    out = bytearray(filt)
    for i in range(len(out)):
        a = out[i - bpp] if i >= bpp else 0
        out[i] = (out[i] + ((a + prior[i]) >> 1)) & 0xFF
    return out


def read_png16(path: str | Path) -> np.ndarray:
    data = Path(path).read_bytes()
    if data[:8] != SIGNATURE:
        raise ValueError(f"{path}: not a PNG file")
    pos = 8
    idat = []
    width = height = bit_depth = color_type = interlace = None
    while pos < len(data):
        (length,) = struct.unpack_from(">I", data, pos)
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, bit_depth, color_type, _comp, _filter, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            break
    if bit_depth != 16 or color_type not in (0, 4) or interlace != 0:
        raise ValueError(f"{path}: need a non-interlaced 16-bit grey (0) or grey+alpha (4) PNG, "
                         f"got depth {bit_depth}, colour type {color_type}, interlace {interlace}")
    bpp = 2 if color_type == 0 else 4
    stride = width * bpp
    raw = zlib.decompress(b"".join(idat))
    rows = np.empty((height, stride), dtype=np.uint8)
    prior = bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind = raw[start]
        filt = raw[start + 1:start + 1 + stride]
        if kind == 0:
            cur = bytearray(filt)
        elif kind == 1:  # Sub: running sum per byte lane.
            lanes = np.frombuffer(filt, dtype=np.uint8).reshape(width, bpp).astype(np.uint32)
            cur = bytearray((np.cumsum(lanes, axis=0) & 0xFF).astype(np.uint8).tobytes())
        elif kind == 2:  # Up
            cur = bytearray(((np.frombuffer(filt, dtype=np.uint8).astype(np.uint16)
                              + np.frombuffer(bytes(prior), dtype=np.uint8)) & 0xFF).astype(np.uint8).tobytes())
        elif kind == 3:
            cur = _average_row(filt, prior, bpp)
        elif kind == 4:
            cur = _paeth_row(filt, prior, bpp)
        else:
            raise ValueError(f"{path}: unknown filter type {kind} in row {y}")
        rows[y] = np.frombuffer(bytes(cur), dtype=np.uint8)
        prior = cur
    samples = rows.reshape(height, width, bpp // 2, 2)
    grey = (samples[:, :, 0, 0].astype(np.uint32) << 8) | samples[:, :, 0, 1]
    return (grey.astype(np.float64) / 65535.0).astype(np.float32)
