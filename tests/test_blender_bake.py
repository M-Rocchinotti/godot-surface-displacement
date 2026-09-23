#!/usr/bin/env python
"""Check tools/bake_displaced_mesh.py, run headless, against an analytic height field.

    python tests/test_blender_bake.py [--blender PATH]

Which Blender: --blender, else the BLENDER_BIN environment variable, else `blender` on
PATH. Needs numpy and Pillow. Exit code: 0 all checks passed, 1 a check failed,
2 Blender not found. Scratch files go to build/test_blender_bake/.

The test writes a 512 x 512 height map of a smooth periodic function h(u, v) (16-bit PNG,
plus an 8-bit copy), runs the tool on primitives with known parameters, and reads the
GLB back with the small stdlib + numpy reader below. It then compares every vertex with
    expected = base surface + normal * height_m * (h(u, v) - midlevel)
using the documented mapping for (u, v). One case uses decimation, which cannot be exact,
so that case checks the triangle budget and the report instead.

TOLERANCE. The tool interpolates bilinearly between texel centres, so the gap to the
exact h is at most the bilinear interpolation error of a C2 function,
    (du^2 / 8) max|h_uu| + (dv^2 / 8) max|h_vv|,   du = dv = 1/512,
plus half a quantisation step of the file (0.5/65535 or 0.5/255). --remap scales both
by 1 / (HI - LO), and height_m turns them into metres. Positions pass through float32
twice (Blender's mesh and the GLB), which adds FLOAT_SLACK. Decoding a 16-bit PNG through
sRGB, a flipped sign, an ignored midlevel, a v flip or a wrong box axis each give errors
three orders of magnitude above this bound.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image

PROJECT = Path(__file__).resolve().parent.parent
TOOL = PROJECT / "tools" / "bake_displaced_mesh.py"
WORK = PROJECT / "build" / "test_blender_bake"
TEXELS = 512
FLOAT_SLACK = 2.5e-7        # metres: a few float32 roundings of coordinates of magnitude <= 1
EDGE_TOLERANCE = 1e-6       # the tool's relative slack on --edge-length


# --------------------------------------------------------------------------- analytic field

def height_field(u: np.ndarray, v: np.ndarray) -> np.ndarray:
    """Periodic over the unit tile (integer frequencies), asymmetric in u and v, range 0.12..0.88."""
    return (0.5 + 0.18 * np.sin(2 * np.pi * (u + 0.11)) + 0.12 * np.sin(2 * np.pi * (2 * v + 0.07))
            + 0.08 * np.sin(2 * np.pi * (3 * u + v) + 0.5))


H_UU = 0.18 * (2 * np.pi) ** 2 + 0.08 * (6 * np.pi) ** 2      # bounds of |d2h/du2| and |d2h/dv2|
H_VV = 0.12 * (4 * np.pi) ** 2 + 0.08 * (2 * np.pi) ** 2
BILINEAR_ERROR = (H_UU + H_VV) / (8 * TEXELS ** 2)


def write_height_maps() -> dict[str, Path]:
    """Pixel (row r, col c) = h((c + 0.5) / N, (r + 0.5) / N); row 0 is the top of the image."""
    centres = (np.arange(TEXELS) + 0.5) / TEXELS
    u, v = np.meshgrid(centres, centres)            # u varies along columns, v along rows
    h = height_field(u, v)
    paths = {"png16": WORK / "height16.png", "png8": WORK / "height8.png"}
    Image.fromarray(np.round(h * 65535).astype(np.uint16)).save(paths["png16"])
    Image.fromarray(np.round(h * 255).astype(np.uint8)).save(paths["png8"])
    back = np.asarray(Image.open(paths["png16"]))
    assert back.dtype == np.uint16 and back.shape == (TEXELS, TEXELS), "Pillow did not write a 16-bit grey PNG"
    return paths


# An OBJ quad (one 4-vertex face, so the importer must triangulate it) at y = QUAD_Y facing +Y,
# x in +-QUAD_X, z in +-QUAD_Z, with OBJ texture coordinates vt = ((x + QUAD_X) / 2QUAD_X,
# (z + QUAD_Z) / 2QUAD_Z). OBJ's v runs UP the image, so the tool must read it as v = 1 - vt.v.
QUAD_X, QUAD_Z, QUAD_Y = 0.6, 0.4, 0.25


def write_quad_obj(path: Path) -> Path:
    corners = [(-QUAD_X, -QUAD_Z), (-QUAD_X, QUAD_Z), (QUAD_X, QUAD_Z), (QUAD_X, -QUAD_Z)]  # CCW from +Y
    lines = [f"v {x} {QUAD_Y} {z}" for x, z in corners]
    lines += [f"vt {(x + QUAD_X) / (2 * QUAD_X)} {(z + QUAD_Z) / (2 * QUAD_Z)}" for x, z in corners]
    lines.append("f 1/1 2/2 3/3 4/4")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def tolerance(case: dict, bits: int) -> float:
    quantisation = 0.5 / (2 ** bits - 1)
    gain = 1.0 / (case["remap"][1] - case["remap"][0]) if case.get("remap") else 1.0
    return case["height_m"] * (BILINEAR_ERROR + quantisation) * gain + FLOAT_SLACK


# --------------------------------------------------------------------------- GLB reader

_COMPONENT = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
_WIDTH = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def read_glb(path: Path) -> tuple[dict, bytes]:
    data = path.read_bytes()
    magic, version, length = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF" or version != 2 or length != len(data):
        raise ValueError(f"{path} is not a glTF 2.0 binary")
    json_length, json_type = struct.unpack_from("<I4s", data, 12)
    if json_type != b"JSON":
        raise ValueError("first GLB chunk is not JSON")
    gltf = json.loads(data[20:20 + json_length])
    offset = 20 + json_length
    bin_length, bin_type = struct.unpack_from("<I4s", data, offset)
    if bin_type != b"BIN\x00":
        raise ValueError("second GLB chunk is not BIN")
    return gltf, data[offset + 8:offset + 8 + bin_length]


def read_accessor(gltf: dict, binary: bytes, index: int) -> np.ndarray:
    accessor = gltf["accessors"][index]
    if "sparse" in accessor or "bufferView" not in accessor:
        raise ValueError("sparse or view-less accessors are not supported by this reader")
    view = gltf["bufferViews"][accessor["bufferView"]]
    dtype, width = np.dtype(_COMPONENT[accessor["componentType"]]), _WIDTH[accessor["type"]]
    start = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    element = dtype.itemsize * width
    stride = view.get("byteStride", element)
    count = accessor["count"]
    raw = np.frombuffer(binary, np.uint8, count=(count - 1) * stride + element, offset=start)
    rows = np.lib.stride_tricks.as_strided(raw, shape=(count, element), strides=(stride, 1))
    return np.ascontiguousarray(rows).view(dtype).reshape(count, width)


def load_mesh(path: Path) -> dict:
    """The single triangle primitive the tool writes, as numpy arrays (plus the accessors)."""
    gltf, binary = read_glb(path)
    nodes = [n for n in gltf["nodes"] if "mesh" in n]
    if len(nodes) != 1 or len(gltf["meshes"]) != 1 or len(gltf["meshes"][0]["primitives"]) != 1:
        raise ValueError("expected exactly one node, one mesh, one primitive")
    if any(k in nodes[0] for k in ("matrix", "translation", "rotation", "scale")):
        raise ValueError("the mesh node has a transform; positions would not be object space")
    prim = gltf["meshes"][0]["primitives"][0]
    if prim.get("mode", 4) != 4:
        raise ValueError("primitive is not a triangle list")
    attributes = {name: read_accessor(gltf, binary, i) for name, i in prim["attributes"].items()}
    return {"attributes": attributes, "indices": read_accessor(gltf, binary, prim["indices"]).reshape(-1, 3),
            "position_accessor": gltf["accessors"][prim["attributes"]["POSITION"]], "gltf": gltf}


# --------------------------------------------------------------------------- helpers

def angle_weighted_normals(pos: np.ndarray, tris: np.ndarray) -> np.ndarray:
    face = np.cross(pos[tris[:, 1]] - pos[tris[:, 0]], pos[tris[:, 2]] - pos[tris[:, 0]])
    face /= np.linalg.norm(face, axis=1, keepdims=True)
    acc = np.zeros_like(pos)
    for k in range(3):
        e1, e2 = pos[tris[:, (k + 1) % 3]] - pos[tris[:, k]], pos[tris[:, (k + 2) % 3]] - pos[tris[:, k]]
        angle = np.arctan2(np.linalg.norm(np.cross(e1, e2), axis=1), np.einsum("ij,ij->i", e1, e2))
        np.add.at(acc, tris[:, k], face * angle[:, None])
    return acc / np.linalg.norm(acc, axis=1, keepdims=True)


def smoothstep(t: np.ndarray) -> np.ndarray:
    t = np.clip(t, 0.0, 1.0)
    return t * t * (3 - 2 * t)


class Checks:
    def __init__(self) -> None:
        self.failed: list[str] = []

    def check(self, case: str, name: str, ok: bool, detail: str) -> None:
        print(f"  {'PASS' if ok else 'FAIL'}  {name}: {detail}")
        if not ok:
            self.failed.append(f"{case}: {name}")


def run_tool(blender: str, arguments: list[str]) -> subprocess.CompletedProcess:
    command = [blender, "-b", "--factory-startup", "-P", str(TOOL), "--", *arguments]
    return subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace",
                          timeout=600)


def case_arguments(case: dict, output: Path, report: Path) -> list[str]:
    source = ["--input", str(case["input"])] if "input" in case else ["--primitive", case["primitive"], "--size", case["size"]]
    args = [*source, "--height", str(case["height"]),
            "--height-m", str(case["height_m"]), "--midlevel", str(case["midlevel"]),
            "--mapping", case["mapping"], "--edge-length", str(case["edge_length"]),
            "--output", str(output), "--report", str(report)]
    for key, flag in (("texture_size_m", "--texture-size-m"), ("border_falloff", "--border-falloff"),
                      ("max_tris", "--max-tris")):
        if key in case:
            args += [flag, str(case[key])]
    for key, flag in (("remap", "--remap"), ("uv_scale", "--uv-scale")):
        if key in case:
            args += [flag, ",".join(str(x) for x in case[key])]
    if case.get("even_offset"):
        args.append("--even-offset")
    return args


def remapped(case: dict, h: np.ndarray) -> np.ndarray:
    if case.get("remap"):
        lo, hi = case["remap"]
        return np.clip((h - lo) / (hi - lo), 0.0, 1.0)
    return h


# --------------------------------------------------------------------------- checks per case

def check_common(checks: Checks, name: str, case: dict, mesh: dict, report: dict) -> None:
    """Output contract and report consistency shared by every case."""
    attrs, tris = mesh["attributes"], mesh["indices"]
    pos = attrs["POSITION"].astype(np.float64)
    checks.check(name, "attributes", all(a in attrs for a in ("POSITION", "NORMAL", "TEXCOORD_0", "TANGENT")),
                 f"{sorted(attrs)}")
    normal = attrs["NORMAL"].astype(np.float64)
    # The GLB splits vertices at UV seams; the tool's normals come from the welded mesh.
    unique, inverse = np.unique(pos, axis=0, return_inverse=True)
    inverse = inverse.reshape(-1)
    recomputed = angle_weighted_normals(unique, inverse[tris.astype(np.int64)])[inverse]
    agreement = np.einsum("ij,ij->i", normal, recomputed).min()
    checks.check(name, "normals smooth, from the displaced surface", agreement > 0.9999,
                 f"min dot(exported, angle-weighted from displaced triangles) = {agreement:.6f}")
    tangent = attrs["TANGENT"].astype(np.float64)
    ortho = np.abs(np.einsum("ij,ij->i", tangent[:, :3], normal)).max()
    checks.check(name, "tangents", bool(np.all(np.abs(np.abs(tangent[:, 3]) - 1) < 1e-6)) and ortho < 1e-3,
                 f"|w| = 1, max |tangent . normal| = {ortho:.2e}")
    acc = mesh["position_accessor"]
    box_ok = (np.allclose(report["bounding_box_m"]["min"], pos.min(0), atol=1e-6)
              and np.allclose(report["bounding_box_m"]["max"], pos.max(0), atol=1e-6)
              and np.allclose(acc["min"], pos.min(0), atol=1e-7) and np.allclose(acc["max"], pos.max(0), atol=1e-7))
    checks.check(name, "report bounding box", box_ok, f"{np.round(pos.min(0), 5)} .. {np.round(pos.max(0), 5)}")
    tri_ok = report["triangles"]["output"] == len(tris) and (
        report["triangles"]["subdivided"] == len(tris) if "max_tris" not in case
        else len(tris) <= case["max_tris"] < report["triangles"]["subdivided"])
    checks.check(name, "report triangles", tri_ok,
                 f"report {report['triangles']}, GLB {len(tris)}")
    p = report["parameters"]
    echoed = (p["height_m"] == case["height_m"] and p["midlevel"] == case["midlevel"]
              and p["mapping"] == case["mapping"] and p["edge_length_m"] == case["edge_length"]
              and p["texture_size_m"] == case.get("texture_size_m")
              and p["remap"] == (list(case["remap"]) if "remap" in case else None)
              and p["max_tris"] == case.get("max_tris")
              and p["even_offset"] == case.get("even_offset", False)
              and report["max_edge_m_subdivided"] <= case["edge_length"] * (1 + EDGE_TOLERANCE))
    checks.check(name, "report parameters", echoed,
                 f"echoed as given; longest subdivided edge {report['max_edge_m_subdivided'] * 1000:.3f} mm")


def check_plane(checks: Checks, name: str, case: dict, mesh: dict, report: dict, bits: int) -> None:
    """A plane on y = 0 facing +Y: exact displacement, no lateral motion, edge bound."""
    pos = mesh["attributes"]["POSITION"].astype(np.float64)
    uv0 = mesh["attributes"]["TEXCOORD_0"].astype(np.float64)
    tris = mesh["indices"].astype(np.int64)
    x, y, z = pos.T
    lateral = 0.0
    for coord in (x, z):                              # x and z must sit exactly on a regular grid
        values = np.unique(np.round(coord, 6))
        grid = np.linspace(-0.5, 0.5, len(values))
        lateral = max(lateral, np.abs(values - grid).max(), np.abs(coord - grid[np.searchsorted(values, np.round(coord, 6))]).max())
    grid_count = len(np.unique(np.round(x, 6))) * len(np.unique(np.round(z, 6)))
    checks.check(name, "no lateral motion", lateral < 1e-6 and grid_count == len(pos) == report["vertices"]["output"],
                 f"x, z on a regular grid within {lateral:.1e} m; {len(pos)} vertices = grid {grid_count} "
                 f"= report {report['vertices']['output']}")
    edges = np.linalg.norm((pos[tris] - pos[np.roll(tris, -1, axis=1)])[:, :, [0, 2]], axis=2).max()
    checks.check(name, "edge length", edges <= case["edge_length"] * (1 + EDGE_TOLERANCE) + FLOAT_SLACK,
                 f"longest undisplaced (x, z) edge {edges * 1000:.3f} mm <= target {case['edge_length'] * 1000:.1f} mm")

    if case["mapping"] == "planar":
        expected_uv = np.stack([x, z], 1) / case["texture_size_m"]
    else:                                             # uv: plane UV0 = (x + 0.5, z + 0.5), times --uv-scale
        expected_uv = np.stack([x + 0.5, z + 0.5], 1) * np.array(case["uv_scale"])
    uv_error = np.abs(uv0 - expected_uv).max()
    checks.check(name, "UV0 = sampling coordinates", uv_error < 1e-5, f"max |UV0 - expected| = {uv_error:.1e}")

    weight = np.ones_like(x)
    if case.get("border_falloff"):                    # nearest border vertex of a grid: straight to the edge
        weight = smoothstep(np.minimum(0.5 - np.abs(x), 0.5 - np.abs(z)) / case["border_falloff"])
    offset = case["height_m"] * (remapped(case, height_field(expected_uv[:, 0], expected_uv[:, 1])) - case["midlevel"]) * weight
    error = np.abs(y - offset)
    tol = tolerance(case, bits)
    checks.check(name, "displacement", error.max() <= tol,
                 f"max |error| {error.max():.3e} m, mean {error.mean():.1e} m, tolerance {tol:.3e} m "
                 f"({error.max() / tol:.2f} of it); relief {offset.min() * 1000:+.2f} .. {offset.max() * 1000:+.2f} mm")
    rep = report["displacement_m"]
    checks.check(name, "report displacement range", abs(rep["min"] - y.min()) < FLOAT_SLACK and abs(rep["max"] - y.max()) < FLOAT_SLACK,
                 f"report {rep['min'] * 1000:+.3f} .. {rep['max'] * 1000:+.3f} mm, GLB y {y.min() * 1000:+.3f} .. {y.max() * 1000:+.3f} mm")


def check_box(checks: Checks, name: str, case: dict, mesh: dict, report: dict, bits: int) -> None:
    """Unit box on y = 0, midlevel 0: every face-interior vertex moved straight out along its
    face normal, by the height read through that face's projection plane; with
    --even-offset, edge vertices keep that full offset from both adjacent faces."""
    pos = mesh["attributes"]["POSITION"].astype(np.float64)
    uv0 = mesh["attributes"]["TEXCOORD_0"].astype(np.float64)
    lo, hi = np.array([-0.5, 0.0, -0.5]), np.array([0.5, 1.0, 0.5])
    outside = (pos < lo - 1e-9) | (pos > hi + 1e-9)
    single = outside.sum(1) == 1                      # face interior; edge vertices move diagonally
    planes = {0: (2, 1), 1: (0, 2), 2: (0, 1)}        # the documented X -> (z, y), Y -> (x, z), Z -> (x, y)
    size, tol = case["texture_size_m"], tolerance(case, bits)
    worst, uv_worst, per_face = 0.0, 0.0, []
    for axis in range(3):
        for sign, face_value in ((-1, lo[axis]), (1, hi[axis])):
            sel = single & outside[:, axis] & (np.sign(pos[:, axis] - face_value) == sign)
            a, b = planes[axis]
            uv = np.stack([pos[sel, a], pos[sel, b]], 1) / size
            expected = face_value + sign * case["height_m"] * (height_field(uv[:, 0], uv[:, 1]) - case["midlevel"])
            worst = max(worst, np.abs(pos[sel, axis] - expected).max(initial=0.0))
            uv_worst = max(uv_worst, np.abs(uv0[sel] - uv).max(initial=0.0))
            per_face.append(int(sel.sum()))
    checks.check(name, "displacement per face", worst <= tol and min(per_face) > 100,
                 f"max |error| {worst:.3e} m, tolerance {tol:.3e} m ({worst / tol:.2f} of it); "
                 f"face-interior vertices checked -X,+X,-Y,+Y,-Z,+Z = {per_face}")
    checks.check(name, "UV0 = box projection of the face", uv_worst < 1e-5, f"max |UV0 - expected| = {uv_worst:.1e}")
    checks.check(name, "vertex count", len(pos) >= report["vertices"]["output"],
                 f"GLB {len(pos)} >= report {report['vertices']['output']} (split at the box-projection seams)")
    if not case.get("even_offset"):
        return
    # A vertex on an edge (two coordinates outside the box) must be offset by the full d from
    # BOTH faces; plain d * normal would give d / sqrt(2), a ridge or groove along the edge.
    # Its normal is diagonal, so either face's projection may have been picked: accept either.
    edge = outside.sum(1) == 2
    base = np.clip(pos, lo, hi)                       # the undisplaced position on the box
    beyond = np.maximum(lo - pos, pos - hi)           # outward offset along each axis
    edge_worst, edge_count = 0.0, 0
    for first, second in ((0, 1), (0, 2), (1, 2)):
        sel = edge & outside[:, first] & outside[:, second]
        candidates = []
        for axis in (first, second):
            uv = base[sel][:, list(planes[axis])] / size
            d = case["height_m"] * (height_field(uv[:, 0], uv[:, 1]) - case["midlevel"])
            candidates.append(np.maximum(np.abs(beyond[sel, first] - d), np.abs(beyond[sel, second] - d)))
        edge_worst = max(edge_worst, np.minimum(*candidates).max(initial=0.0))
        edge_count += int(sel.sum())
    checks.check(name, "even offset along box edges", edge_worst <= tol and edge_count > 100,
                 f"{edge_count} edge vertices offset by d from both faces: max |error| {edge_worst:.3e} m "
                 f"(tolerance {tol:.3e} m)")


def check_obj_quad(checks: Checks, name: str, case: dict, mesh: dict, report: dict, bits: int) -> None:
    """--input OBJ: import axes, OBJ UV convention, and the edge-splitting refinement of two
    long, thin triangles (irregular result, so no grid check: bounds and exact heights)."""
    pos = mesh["attributes"]["POSITION"].astype(np.float64)
    uv0 = mesh["attributes"]["TEXCOORD_0"].astype(np.float64)
    tris = mesh["indices"].astype(np.int64)
    x, y, z = pos.T
    inside = np.all(np.abs(x) <= QUAD_X + 1e-6) and np.all(np.abs(z) <= QUAD_Z + 1e-6)
    checks.check(name, "import and refinement", inside and report["triangles"]["base"] == 2
                 and report["triangles"]["subdivided"] == len(tris) and report["vertices"]["output"] == len(pos),
                 f"quad face -> {report['triangles']['base']} triangles -> {len(tris)} after edge splitting, "
                 f"{len(pos)} vertices, all within the quad")
    edges = np.linalg.norm((pos[tris] - pos[np.roll(tris, -1, axis=1)])[:, :, [0, 2]], axis=2).max()
    checks.check(name, "edge length", edges <= case["edge_length"] * (1 + EDGE_TOLERANCE) + FLOAT_SLACK,
                 f"longest undisplaced (x, z) edge {edges * 1000:.3f} mm <= target {case['edge_length'] * 1000:.1f} mm")
    expected_uv = np.stack([(x + QUAD_X) / (2 * QUAD_X), 1.0 - (z + QUAD_Z) / (2 * QUAD_Z)], 1) * np.array(case["uv_scale"])
    uv_error = np.abs(uv0 - expected_uv).max()
    checks.check(name, "UV0 = OBJ vt with v flipped, times --uv-scale", uv_error < 1e-5,
                 f"max |UV0 - expected| = {uv_error:.1e}")
    offset = case["height_m"] * (height_field(expected_uv[:, 0], expected_uv[:, 1]) - case["midlevel"])
    error = np.abs(y - QUAD_Y - offset)
    tol = tolerance(case, bits)
    checks.check(name, "displacement", error.max() <= tol,
                 f"max |error| {error.max():.3e} m, tolerance {tol:.3e} m ({error.max() / tol:.2f} of it)")


def check_decimated(checks: Checks, name: str, case: dict, mesh: dict, report: dict) -> None:
    """Decimation moves vertices off the exact surface (quadric placement); only a loose sanity bound."""
    pos = mesh["attributes"]["POSITION"].astype(np.float64)
    u, v = pos[:, 0] / case["texture_size_m"], pos[:, 2] / case["texture_size_m"]
    error = np.abs(pos[:, 1] - case["height_m"] * (height_field(u, v) - case["midlevel"]))
    checks.check(name, "decimated surface stays on the relief", error.max() < 0.1 * case["height_m"],
                 f"max |error| {error.max() * 1000:.2f} mm, median {np.median(error) * 1000:.3f} mm "
                 f"(loose bound: 10% of height_m)")
    checks.check(name, "decimation ratio reported", report["decimation_ratio"] is not None and 0 < report["decimation_ratio"] < 1,
                 f"ratio {report['decimation_ratio']}")


def check_errors(checks: Checks, blender: str, maps: dict[str, Path]) -> None:
    out = WORK / "error_case.glb"
    missing = run_tool(blender, ["--primitive", "plane", "--size", "1,0,1", "--height", str(WORK / "missing.png"),
                                 "--height-m", "0.1", "--mapping", "planar", "--texture-size-m", "1",
                                 "--edge-length", "0.1", "--output", str(out)])
    checks.check("errors", "missing height map", missing.returncode == 1 and "file not found" in missing.stderr,
                 f"exit {missing.returncode}, stderr: {missing.stderr.strip().splitlines()[-1] if missing.stderr.strip() else ''}")
    bad = run_tool(blender, ["--primitive", "plane", "--size", "1,0,1", "--height", str(maps["png16"]),
                             "--height-m", "0.1", "--midlevel", "1.5", "--mapping", "planar",
                             "--texture-size-m", "1", "--edge-length", "0.1", "--output", str(out)])
    checks.check("errors", "bad argument", bad.returncode == 2 and "--midlevel" in bad.stderr,
                 f"exit {bad.returncode}, stderr: {bad.stderr.strip().splitlines()[-1] if bad.stderr.strip() else ''}")


# --------------------------------------------------------------------------- main

def find_blender(explicit: str | None) -> str | None:
    for candidate in (explicit, os.environ.get("BLENDER_BIN")):
        if candidate:
            return candidate if Path(candidate).is_file() else None
    return shutil.which("blender")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--blender", help="path to the Blender executable")
    blender = find_blender(parser.parse_args().blender)
    if blender is None:
        print("Blender not found: pass --blender PATH, set BLENDER_BIN, or put `blender` on PATH.", file=sys.stderr)
        return 2
    WORK.mkdir(parents=True, exist_ok=True)
    maps = write_height_maps()
    plane = {"primitive": "plane", "size": "1,0,1"}
    cases = [
        ("planar, relief outwards", dict(plane, mapping="planar", height=maps["png16"], height_m=0.1,
                                         midlevel=0.0, texture_size_m=0.7, edge_length=0.02), 16),
        ("planar, both ways + remap + border falloff",
         dict(plane, mapping="planar", height=maps["png16"], height_m=0.08, midlevel=0.5,
              remap=(0.2, 0.8), texture_size_m=0.45, border_falloff=0.15, edge_length=0.025), 16),
        ("uv mapping, scaled", dict(plane, mapping="uv", height=maps["png16"], height_m=0.06, midlevel=0.25,
                                    uv_scale=(2.0, 3.0), edge_length=0.02), 16),
        ("planar, 8-bit PNG", dict(plane, mapping="planar", height=maps["png8"], height_m=0.1, midlevel=0.5,
                                   texture_size_m=0.7, edge_length=0.03), 8),
        ("box mapping on a box, even offset",
         dict(primitive="box", size="1,1,1", mapping="box", height=maps["png16"], height_m=0.05,
              midlevel=0.0, texture_size_m=0.8, edge_length=0.05, even_offset=True), 16),
        ("OBJ input, uv mapping", dict(input=write_quad_obj(WORK / "quad.obj"), mapping="uv", height=maps["png16"],
                                       height_m=0.05, midlevel=0.5, uv_scale=(1.5, 2.0), edge_length=0.03), 16),
        ("planar + decimation", dict(plane, mapping="planar", height=maps["png16"], height_m=0.1, midlevel=0.0,
                                     texture_size_m=0.7, edge_length=0.02, max_tris=3000), 16),
    ]
    checks = Checks()
    print(f"Blender: {blender}\nbilinear error bound {BILINEAR_ERROR:.2e} (height units), "
          f"16-bit step/2 {0.5 / 65535:.2e}, 8-bit step/2 {0.5 / 255:.2e}")
    for index, (name, case, bits) in enumerate(cases):
        print(f"\n[{name}]")
        output, report_path = WORK / f"case{index}.glb", WORK / f"case{index}.json"
        for stale in (output, report_path):
            stale.unlink(missing_ok=True)
        result = run_tool(blender, case_arguments(case, output, report_path))
        if result.returncode != 0 or not output.is_file():
            checks.check(name, "tool run", False, f"exit {result.returncode}\n{result.stdout[-2000:]}\n{result.stderr[-2000:]}")
            continue
        mesh = load_mesh(output)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        check_common(checks, name, case, mesh, report)
        if "max_tris" in case:
            check_decimated(checks, name, case, mesh, report)
        elif "input" in case:
            check_obj_quad(checks, name, case, mesh, report, bits)
        elif case["primitive"] == "box":
            check_box(checks, name, case, mesh, report, bits)
        else:
            check_plane(checks, name, case, mesh, report, bits)
    print("\n[error handling]")
    check_errors(checks, blender, maps)

    if checks.failed:
        print(f"\nFAILED ({len(checks.failed)}):\n  " + "\n  ".join(checks.failed))
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
