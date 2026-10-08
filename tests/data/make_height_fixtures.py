"""Writes the height-map fixtures the logic tests decode (tests/run_logic_tests.gd, test_height_import):
16-bit PNGs (every PNG row filter in turn) and RAW / R16 files of known values.

    python tests/data/make_height_fixtures.py
"""
import struct
import zlib
from pathlib import Path

HERE = Path(__file__).parent


def value(x: int, y: int) -> int:
    return (x * 1031 + y * 517 + (x * y) % 97) % 65536


def chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def png16(path: Path, width: int, height: int, colour_type: int, pixel) -> None:
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[colour_type]
    bpp = 2 * channels
    rows = [b"".join(struct.pack(">" + "H" * channels, *pixel(x, y)) for x in range(width)) for y in range(height)]
    out = bytearray()
    prev = bytes(len(rows[0]))
    for y, cur in enumerate(rows):
        f = y % 5  # None, Sub, Up, Average, Paeth
        enc = bytearray()
        for i, v in enumerate(cur):
            a = cur[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            pred = [0, a, b, (a + b) // 2, paeth(a, b, c)][f]
            enc.append((v - pred) & 255)
        out.append(f)
        out += enc
        prev = cur
    ihdr = struct.pack(">IIBBBBB", width, height, 16, colour_type, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(out), 9)) + chunk(b"IEND", b""))


def raw16(path: Path, width: int, height: int, big_endian: bool) -> None:
    order = ">" if big_endian else "<"
    path.write_bytes(b"".join(struct.pack(order + "H", value(x, y)) for y in range(height) for x in range(width)))


png16(HERE / "height16_grey.png", 67, 45, 0, lambda x, y: (value(x, y),))
png16(HERE / "height16_rgba.png", 33, 21, 6,
      lambda x, y: (value(x, y), 65535 - value(x, y), (value(x, y) * 3) % 65536, (value(x, y) * 7) % 65536))
raw16(HERE / "height16_le.r16", 40, 40, False)
raw16(HERE / "height16_be.raw", 48, 20, True)
print("written")
