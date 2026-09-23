"""Minimal OpenEXR reader and writer (numpy + zlib, no OpenEXR library needed).

Godot 4.7 loads EXR through tinyexr, which reads NO, RLE, ZIPS, ZIP and PIZ compression but not
DWAA/DWAB. Several Poly Haven height maps ship as DWAA, and Godot turns 16-bit PNG into 8 bit on
import, so the texture tools convert every height map to a single-channel EXR themselves.

Supported here (enough for height maps and look-up tables):
    - single-part scanline images, INCREASING_Y line order
    - pixel types HALF and FLOAT
    - compression NO (0), ZIPS (2) and ZIP (3) for reading; NO and ZIP for writing

A single channel named "R" loads in Godot as Image.FORMAT_RH / FORMAT_RF (one channel). A channel
named "Y" loads as three identical channels, which triples the texture memory, so write "R".

    from exr import read_exr, write_exr
    channels = read_exr("height.exr")          # {"Y": float32 array (h, w)}
    write_exr("out.exr", {"R": data}, half=True, compression="zip")
"""
from __future__ import annotations

import struct
import zlib
from pathlib import Path

import numpy as np

MAGIC = 20000630
COMPRESSION = {"none": 0, "zips": 2, "zip": 3}
LINES_PER_CHUNK = {0: 1, 2: 1, 3: 16}
PIXEL_HALF = 1
PIXEL_FLOAT = 2


def _read_attributes(data: bytes, pos: int) -> tuple[dict, int]:
    attrs = {}
    while True:
        end = data.index(b"\0", pos)
        name = data[pos:end].decode()
        pos = end + 1
        if not name:
            return attrs, pos
        end = data.index(b"\0", pos)
        kind = data[pos:end].decode()
        pos = end + 1
        (size,) = struct.unpack_from("<i", data, pos)
        pos += 4
        attrs[name] = (kind, data[pos:pos + size])
        pos += size


def _parse_channels(raw: bytes) -> list[tuple[str, int]]:
    channels = []
    pos = 0
    while raw[pos] != 0:
        end = raw.index(b"\0", pos)
        name = raw[pos:end].decode()
        pos = end + 1
        pixel_type, _linear, x_sampling, y_sampling = struct.unpack_from("<iB3xii", raw, pos)
        pos += 16
        if x_sampling != 1 or y_sampling != 1:
            raise ValueError(f"channel {name}: subsampled channels are not supported")
        channels.append((name, pixel_type))
    return channels


def _unzip(block: bytes, expected: int) -> bytes:
    """Inverse of OpenEXR's ZIP filter: inflate, undo the byte predictor, re-interleave."""
    t = np.frombuffer(zlib.decompress(block), dtype=np.uint8)
    if t.size != expected:
        raise ValueError(f"ZIP block inflated to {t.size} bytes, expected {expected}")
    # Predictor: stored d[i] = t[i] - t[i-1] + 128 (mod 256); cumulative sum undoes it.
    d = t.astype(np.int64)
    d[1:] -= 128
    t = (np.cumsum(d) & 0xFF).astype(np.uint8)
    half = (expected + 1) // 2
    out = np.empty(expected, dtype=np.uint8)
    out[0::2] = t[:half]
    out[1::2] = t[half:]
    return out.tobytes()


def _zip(raw: bytes) -> bytes:
    """OpenEXR's ZIP filter: split even/odd bytes, byte-delta predictor, deflate."""
    b = np.frombuffer(raw, dtype=np.uint8)
    t = np.concatenate([b[0::2], b[1::2]]).astype(np.int64)
    d = t.copy()
    d[1:] = (t[1:] - t[:-1] + 128 + 256) & 0xFF
    return zlib.compress(d.astype(np.uint8).tobytes(), 9)


def read_exr(path: str | Path) -> dict[str, np.ndarray]:
    """All channels of a scanline EXR as float32 arrays of shape (height, width)."""
    data = Path(path).read_bytes()
    magic, version = struct.unpack_from("<iI", data, 0)
    if magic != MAGIC:
        raise ValueError(f"{path}: not an OpenEXR file")
    if version & 0x200 or version & 0x1000:
        raise ValueError(f"{path}: tiled or multi-part EXR files are not supported")
    attrs, pos = _read_attributes(data, 8)
    channels = _parse_channels(attrs["channels"][1])
    compression = attrs["compression"][1][0]
    if compression not in LINES_PER_CHUNK:
        raise ValueError(f"{path}: compression {compression} is not supported (only NO, ZIPS, ZIP)")
    x0, y0, x1, y1 = struct.unpack("<4i", attrs["dataWindow"][1])
    width, height = x1 - x0 + 1, y1 - y0 + 1
    lines = LINES_PER_CHUNK[compression]
    chunks = (height + lines - 1) // lines
    offsets = struct.unpack_from(f"<{chunks}Q", data, pos)
    sizes = [2 if t == PIXEL_HALF else 4 for _, t in channels]
    row_bytes = width * sum(sizes)
    out = {name: np.empty((height, width), dtype=np.float32) for name, _ in channels}
    for offset in offsets:
        y, size = struct.unpack_from("<ii", data, offset)
        block = data[offset + 8: offset + 8 + size]
        n_lines = min(lines, y1 + 1 - y)
        expected = n_lines * row_bytes
        raw = block if compression == 0 or size == expected else _unzip(block, expected)
        at = 0
        for line in range(n_lines):
            row = y - y0 + line
            for (name, pixel_type), bpp in zip(channels, sizes):
                dtype = "<f2" if pixel_type == PIXEL_HALF else "<f4"
                out[name][row] = np.frombuffer(raw, dtype=dtype, count=width, offset=at)
                at += width * bpp
    return out


def write_exr(path: str | Path, channels: dict[str, np.ndarray], half: bool = True,
              compression: str = "zip") -> None:
    """Writes float arrays (all the same shape (height, width)) as a scanline EXR."""
    names = sorted(channels)
    arrays = [np.asarray(channels[n], dtype=np.float32) for n in names]
    height, width = arrays[0].shape
    if any(a.shape != (height, width) for a in arrays):
        raise ValueError("all channels must have the same shape")
    code = COMPRESSION[compression]
    if code == 2:
        raise ValueError("write 'zip' (16 lines per chunk) or 'none'")
    pixel_type = PIXEL_HALF if half else PIXEL_FLOAT
    dtype = "<f2" if half else "<f4"

    def attribute(name: str, kind: str, value: bytes) -> bytes:
        return name.encode() + b"\0" + kind.encode() + b"\0" + struct.pack("<i", len(value)) + value

    chlist = b"".join(n.encode() + b"\0" + struct.pack("<iB3xii", pixel_type, 0, 1, 1) for n in names) + b"\0"
    box = struct.pack("<4i", 0, 0, width - 1, height - 1)
    header = struct.pack("<iI", MAGIC, 2)
    header += attribute("channels", "chlist", chlist)
    header += attribute("compression", "compression", bytes([code]))
    header += attribute("dataWindow", "box2i", box)
    header += attribute("displayWindow", "box2i", box)
    header += attribute("lineOrder", "lineOrder", bytes([0]))
    header += attribute("pixelAspectRatio", "float", struct.pack("<f", 1.0))
    header += attribute("screenWindowCenter", "v2f", struct.pack("<2f", 0.0, 0.0))
    header += attribute("screenWindowWidth", "float", struct.pack("<f", 1.0))
    header += b"\0"
    lines = LINES_PER_CHUNK[code]
    typed = [a.astype(dtype) for a in arrays]
    chunks = []
    for y in range(0, height, lines):
        n_lines = min(lines, height - y)
        raw = b"".join(t[y + line].tobytes() for line in range(n_lines) for t in typed)
        payload = raw
        if code == 3:
            packed = _zip(raw)
            if len(packed) < len(raw):
                payload = packed
        chunks.append(struct.pack("<ii", y, len(payload)) + payload)
    table_size = 8 * len(chunks)
    offset = len(header) + table_size
    table = b""
    for chunk in chunks:
        table += struct.pack("<Q", offset)
        offset += len(chunk)
    Path(path).write_bytes(header + table + b"".join(chunks))


if __name__ == "__main__":
    # Self-test: round trip through both compressions and both pixel types.
    rng = np.random.default_rng(1)
    img = rng.random((37, 53)).astype(np.float32)
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        for comp in ("none", "zip"):
            for half in (True, False):
                p = Path(tmp) / f"t_{comp}_{half}.exr"
                write_exr(p, {"R": img, "G": img * 0.5}, half=half, compression=comp)
                back = read_exr(p)
                ref = img.astype(np.float16).astype(np.float32) if half else img
                assert np.array_equal(back["R"], ref), (comp, half)
                assert np.array_equal(back["G"], (img * 0.5).astype(np.float16).astype(np.float32) if half else img * 0.5)
    print("exr.py self-test OK")
