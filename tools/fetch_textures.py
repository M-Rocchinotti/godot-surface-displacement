#!/usr/bin/env python
"""Download reference PBR texture sets, with float displacement maps, from Poly Haven.

The surface-displacement work needs height maps with more than 8 bits of precision; a JPG or
PNG height map terraces visibly once it is displaced. Poly Haven (https://polyhaven.com)
publishes every texture under CC0-1.0 and ships its displacement maps as float EXR, so this
tool fetches, per asset id and at one resolution (default 2k):

    Displacement  EXR   -> manifest key height_exr (the reason this tool exists)
    Diffuse       JPG   -> albedo
    nor_gl        JPG   -> normal_gl (OpenGL convention, +Y up, as Godot expects)
    arm           JPG   -> arm (R = AO, G = roughness, B = metallic)
    Rough + AO    JPG   -> rough, ao (only when a set has no arm map)
    Displacement  PNG   -> height_png16 (only when Godot cannot read the set's EXR, see below)

Some Poly Haven EXRs are DWAA-compressed, which Godot's EXR loader (tinyexr) cannot decode
and which is lossy besides. For those sets the 16-bit Displacement PNG is fetched as well,
and each set's manifest entry says which file to use in height_source ("exr" or "png16").

Files keep Poly Haven's names and go to <dest>/<asset id>/. The destination is --dest, else
the GADS_TEXTURE_CACHE environment variable, else E:\\dev-cache\\polyhaven-hq. Next to the
maps each set gets <id>.license.json (license, source page, authors, the exact URLs,
retrieval date, real-world size), and <dest>/manifest.json lists every set's local paths,
md5s, byte sizes, real-world size in metres and what its height files contain (EXR channel
names, pixel types and compression; PNG bit depth and colour type), read with small
built-in header parsers.

Every file is checked against the md5 the API publishes. A file already on disk with the
right md5 is skipped, so an interrupted run can simply be repeated. Downloads are sequential
and retried with exponential backoff; the API asks clients for a descriptive User-Agent.

Usage:
    python tools/fetch_textures.py                     # the default sets
    python tools/fetch_textures.py rubble brick_wall_001
    python tools/fetch_textures.py --res 4k --dest D:/textures
    python tools/fetch_textures.py --list              # print the default set ids

Exit code is 0 when every requested set is complete, 1 otherwise.
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import re
import struct
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

API = "https://api.polyhaven.com"
USER_AGENT = "godot-surface-displacement-texture-fetch/0.1 (github.com/M-Rocchinotti)"
DEFAULT_DEST = Path(r"E:\dev-cache\polyhaven-hq")
DEST_ENV = "GADS_TEXTURE_CACHE"
LICENSE = "CC0-1.0"
LICENSE_URL = "https://creativecommons.org/publicdomain/zero/1.0/"

DEFAULT_IDS = [
    "gravel_stones", "rocky_gravel", "clean_pebbles",
    "cobblestone_floor_08", "cobblestone_floor_03", "cobblestone_floor_07", "cobblestone_floor_13",
    "square_cobblestone",
    "rocks_ground_02", "rocks_ground_04", "rocks_ground_05", "rocks_ground_06",
    "rubble", "brick_wall_001",
]

# Manifest key -> (Poly Haven map key, file formats in order of preference).
MAP_SOURCES = {
    "albedo": ("Diffuse", ("jpg", "png")),
    "normal_gl": ("nor_gl", ("jpg", "png")),
    "arm": ("arm", ("jpg", "png")),
    "rough": ("Rough", ("jpg", "png")),
    "ao": ("AO", ("jpg", "png")),
    "height_exr": ("Displacement", ("exr",)),
    "height_png16": ("Displacement", ("png",)),
}
WITH_ARM = ["albedo", "normal_gl", "arm", "height_exr"]
WITHOUT_ARM = ["albedo", "normal_gl", "rough", "ao", "height_exr"]

ATTEMPTS = 4
BACKOFF_SECONDS = 2
TIMEOUT_SECONDS = 60
CHUNK_BYTES = 1 << 20

EXR_MAGIC = bytes([0x76, 0x2F, 0x31, 0x01])
EXR_PIXEL_TYPES = {0: "UINT", 1: "HALF", 2: "FLOAT"}
EXR_COMPRESSIONS = ["NONE", "RLE", "ZIPS", "ZIP", "PIZ", "PXR24", "B44", "B44A", "DWAA", "DWAB"]
EXR_TILED_FLAG = 0x200
EXR_MULTIPART_FLAG = 0x1000
# EXR compressions treated as loadable by Godot. Deliberately conservative: tinyexr also reads
# RLE, PIZ, PXR24 and B44, but never DWAA/DWAB, and Poly Haven ships ZIP or DWAA.
GODOT_EXR_COMPRESSIONS = {"NONE", "ZIPS", "ZIP"}

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
PNG_COLOR_TYPES = {0: "grey", 2: "rgb", 3: "indexed", 4: "grey+alpha", 6: "rgba"}


class FetchError(Exception):
    """An API call or download failed for good."""


class ChecksumMismatch(ValueError):
    """A downloaded file's md5 differs from the one the API published."""


# --- HTTP -------------------------------------------------------------------------------

def _request(url: str) -> urllib.request.Request:
    return urllib.request.Request(url, headers={"User-Agent": USER_AGENT})


def _with_retries(action, what: str):
    """Run action(), retrying transient failures (network, 5xx, 429, bad checksum) with backoff."""
    for attempt in range(1, ATTEMPTS + 1):
        try:
            return action()
        except urllib.error.HTTPError as err:
            if err.code != 429 and err.code < 500:
                raise FetchError(f"{what}: HTTP {err.code}") from err
            problem = f"HTTP {err.code}"
        except (OSError, http.client.HTTPException, ValueError) as err:
            problem = f"{type(err).__name__}: {err}"
        if attempt == ATTEMPTS:
            raise FetchError(f"{what}: {problem} (gave up after {ATTEMPTS} attempts)")
        delay = BACKOFF_SECONDS * 2 ** (attempt - 1)
        print(f"    retry in {delay}s ({problem})")
        time.sleep(delay)


def api_json(path: str) -> dict:
    def fetch():
        with urllib.request.urlopen(_request(f"{API}/{path}"), timeout=TIMEOUT_SECONDS) as resp:
            return json.load(resp)
    return _with_retries(fetch, f"GET {API}/{path}")


def file_md5(path: Path) -> str:
    digest = hashlib.md5(usedforsecurity=False)
    with path.open("rb") as f:
        while chunk := f.read(CHUNK_BYTES):
            digest.update(chunk)
    return digest.hexdigest()


def download(entry: dict, target: Path) -> bool:
    """Fetch entry["url"] to target via a .part file. False if target already had the right md5."""
    if target.is_file() and target.stat().st_size == entry["size"] and file_md5(target) == entry["md5"]:
        return False
    part = target.with_name(target.name + ".part")

    def fetch():
        digest = hashlib.md5(usedforsecurity=False)
        with urllib.request.urlopen(_request(entry["url"]), timeout=TIMEOUT_SECONDS) as resp, \
                part.open("wb") as out:
            while chunk := resp.read(CHUNK_BYTES):
                digest.update(chunk)
                out.write(chunk)
        if digest.hexdigest() != entry["md5"]:
            raise ChecksumMismatch(f"md5 {digest.hexdigest()}, expected {entry['md5']}")
        part.replace(target)

    try:
        _with_retries(fetch, entry["url"])
    finally:
        part.unlink(missing_ok=True)
    return True


# --- OpenEXR header ---------------------------------------------------------------------

def _read_cstring(f) -> str:
    raw = bytearray()
    while (byte := f.read(1)) != b"\0":
        if not byte:
            raise ValueError("truncated OpenEXR header")
        raw += byte
    return raw.decode("latin-1")


def _decode_chlist(value: bytes) -> list[dict]:
    """chlist: per channel a NUL-terminated name, int32 pixel type, uint8 pLinear, 3 reserved
    bytes, int32 x/y sampling; the list ends with an empty name."""
    channels, pos = [], 0
    while value[pos] != 0:
        end = value.index(b"\0", pos)
        name = value[pos:end].decode("latin-1")
        pixel_type, _linear, x_sampling, y_sampling = struct.unpack_from("<iB3xii", value, end + 1)
        channels.append({"name": name, "pixel_type": EXR_PIXEL_TYPES.get(pixel_type, f"unknown({pixel_type})"),
                         "sampling": [x_sampling, y_sampling]})
        pos = end + 1 + 16
    return channels


def read_exr_header(path: Path) -> dict:
    """Decode channels, compression and data window from an OpenEXR file's (first) header.

    Layout: 4-byte magic, 4-byte version/flags, then attributes (NUL-terminated name,
    NUL-terminated type, int32 size, value) until an empty name.
    """
    wanted = {"channels", "compression", "dataWindow"}
    attrs = {}
    with path.open("rb") as f:
        if f.read(4) != EXR_MAGIC:
            raise ValueError(f"{path.name} is not an OpenEXR file")
        (version,) = struct.unpack("<I", f.read(4))
        while name := _read_cstring(f):
            _read_cstring(f)  # attribute type; the three we decode have fixed types
            (size,) = struct.unpack("<i", f.read(4))
            if name in wanted:
                attrs[name] = f.read(size)
            else:
                f.seek(size, os.SEEK_CUR)
    missing = wanted - attrs.keys()
    if missing:
        raise ValueError(f"{path.name}: OpenEXR header lacks {sorted(missing)}")
    x_min, y_min, x_max, y_max = struct.unpack("<4i", attrs["dataWindow"])
    compression = attrs["compression"][0]
    return {
        "channels": _decode_chlist(attrs["channels"]),
        "compression": (EXR_COMPRESSIONS[compression] if compression < len(EXR_COMPRESSIONS)
                        else f"unknown({compression})"),
        "data_window": [x_min, y_min, x_max, y_max],
        "size": [x_max - x_min + 1, y_max - y_min + 1],
        "tiled": bool(version & EXR_TILED_FLAG),
        "multipart": bool(version & EXR_MULTIPART_FLAG),
    }


def read_png_header(path: Path) -> dict:
    """Decode size, bit depth and colour type from a PNG's IHDR chunk, which must come first."""
    with path.open("rb") as f:
        head = f.read(8 + 8 + 13)  # signature, chunk length + type, IHDR data
    if len(head) < 29 or head[:8] != PNG_SIGNATURE or head[12:16] != b"IHDR":
        raise ValueError(f"{path.name} is not a PNG file")
    width, height, bit_depth, color_type = struct.unpack(">IIBB", head[16:26])
    return {"size": [width, height], "bit_depth": bit_depth, "color_type": color_type,
            "color_type_name": PNG_COLOR_TYPES.get(color_type, "unknown")}


# --- one texture set --------------------------------------------------------------------

def pick_file(files: dict, manifest_key: str, res: str) -> dict | None:
    """The API file entry for a map at res in its preferred available format, or None."""
    map_key, formats = MAP_SOURCES[manifest_key]
    by_format = files.get(map_key, {}).get(res, {})
    return next((by_format[fmt] for fmt in formats if fmt in by_format), None)


def write_json(path: Path, data: dict) -> None:
    part = path.with_name(path.name + ".part")
    part.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    part.replace(path)


def fetch_set(asset_id: str, dest: Path, res: str, stats: dict) -> dict:
    """Download one set and write its license file. Returns its manifest entry."""
    files = api_json(f"files/{asset_id}")
    info = api_json(f"info/{asset_id}")
    set_dir = dest / asset_id
    set_dir.mkdir(parents=True, exist_ok=True)

    maps = dict.fromkeys(MAP_SOURCES)
    missing, urls, local_files = [], [], []

    def fetch_map(key: str) -> bool:
        entry = pick_file(files, key, res)
        if entry is None:
            missing.append(key)
            print(f"  {key:<12} MISSING ({MAP_SOURCES[key][0]} at {res})")
            return False
        target = set_dir / entry["url"].rsplit("/", 1)[-1]
        fresh = download(entry, target)
        stats["downloaded" if fresh else "skipped"] += 1
        stats["bytes"] += entry["size"] if fresh else 0
        print(f"  {key:<12} {target.name:<42} {entry['size'] / 1e6:6.1f} MB  "
              f"{'downloaded' if fresh else 'present, md5 ok'}")
        maps[key] = {"path": target.relative_to(dest).as_posix(), "md5": entry["md5"], "bytes": entry["size"]}
        urls.append(entry["url"])
        local_files.append(target)
        return True

    for key in WITH_ARM if pick_file(files, "arm", res) else WITHOUT_ARM:
        fetch_map(key)

    exr_header = png_header = height_source = None
    if maps["height_exr"]:
        exr_header = read_exr_header(dest / maps["height_exr"]["path"])
        channels = ", ".join(f"{c['name']}:{c['pixel_type']}" for c in exr_header["channels"])
        print(f"  height EXR   {channels}; {exr_header['compression']}; {exr_header['size']}")
    if exr_header and exr_header["compression"] in GODOT_EXR_COMPRESSIONS:
        height_source = "exr"
    elif fetch_map("height_png16"):
        png_header = read_png_header(dest / maps["height_png16"]["path"])
        print(f"  height PNG   {png_header['bit_depth']}-bit {png_header['color_type_name']}; {png_header['size']}")
        if png_header["bit_depth"] != 16:
            raise ValueError(f"{asset_id}: Displacement PNG is {png_header['bit_depth']}-bit, not 16-bit")
        height_source = "png16"

    dimensions_mm = info.get("dimensions")  # the API documents these as millimetres per axis
    size_m = [round(v / 1000, 4) for v in dimensions_mm] if dimensions_mm else None
    # Retrieval date = when the newest file landed; a re-run that only verifies keeps it.
    newest = max((f.stat().st_mtime for f in local_files), default=time.time())
    write_json(set_dir / f"{asset_id}.license.json", {
        "asset": asset_id,
        "name": info.get("name"),
        "license": LICENSE,
        "license_url": LICENSE_URL,
        "source": f"https://polyhaven.com/a/{asset_id}",
        "authors": info.get("authors"),
        "files": urls,
        "retrieved": datetime.fromtimestamp(newest, timezone.utc).date().isoformat(),
        "dimensions_m": size_m,
    })
    return {
        "name": info.get("name"),
        "resolution": res,
        "size_m": size_m,
        "license_file": f"{asset_id}/{asset_id}.license.json",
        "maps": maps,
        "height_source": height_source,
        "height_exr_header": exr_header,
        "height_png16_header": png_header,
        "missing_maps": missing,
    }


# --- CLI --------------------------------------------------------------------------------

def asset_id_arg(value: str) -> str:
    if not re.fullmatch(r"[a-z0-9_]+", value):
        raise argparse.ArgumentTypeError(f"not a Poly Haven asset id: {value!r}")
    return value


def resolution_arg(value: str) -> str:
    if not re.fullmatch(r"\d+k", value):
        raise argparse.ArgumentTypeError(f"resolution must look like 1k, 2k, 4k: {value!r}")
    return value


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ids", nargs="*", type=asset_id_arg, help="Poly Haven asset ids (default: the built-in list)")
    parser.add_argument("--dest", type=Path, help=f"destination folder (default: ${DEST_ENV} or {DEFAULT_DEST})")
    parser.add_argument("--res", type=resolution_arg, default="2k", help="resolution to fetch (default: 2k)")
    parser.add_argument("--list", action="store_true", help="print the default asset ids and exit")
    args = parser.parse_args(argv)

    if args.list:
        print("\n".join(DEFAULT_IDS))
        return 0

    dest = (args.dest or Path(os.environ.get(DEST_ENV) or DEFAULT_DEST)).resolve()
    dest.mkdir(parents=True, exist_ok=True)
    manifest_path = dest / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.is_file() else {}
    manifest.update({"source": "Poly Haven (https://polyhaven.com)", "license": LICENSE,
                     "paths": "relative to the directory containing this manifest"})
    manifest.setdefault("sets", {})

    ids = args.ids or DEFAULT_IDS
    stats = {"downloaded": 0, "skipped": 0, "bytes": 0}
    failed, incomplete = [], []
    for index, asset_id in enumerate(ids, 1):
        print(f"[{index}/{len(ids)}] {asset_id}")
        try:
            entry = fetch_set(asset_id, dest, args.res, stats)
        except (FetchError, OSError, ValueError) as err:
            print(f"  FAILED: {err}")
            failed.append(asset_id)
            continue
        manifest["sets"][asset_id] = entry
        if entry["missing_maps"]:
            incomplete.append(asset_id)
        manifest["updated"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
        write_json(manifest_path, manifest)

    print(f"\n{stats['downloaded']} files downloaded ({stats['bytes'] / 1e6:.1f} MB), "
          f"{stats['skipped']} already present. Manifest: {manifest_path}")
    if incomplete:
        print(f"Sets missing maps: {', '.join(incomplete)}")
    if failed:
        print(f"Failed sets: {', '.join(failed)}")
    return 1 if failed or incomplete else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
