"""Offline hero bake: real subdivided and displaced geometry for a few hero props.

Surface displacement in this addon is parallax occlusion mapping (no silhouette) plus
displaced geometry near the camera. This tool is the third option: for the few props
whose silhouette matters, it bakes the relief into real triangles, offline, in Blender.

    base mesh (--input FILE or --primitive)
      -> linear subdivision until no edge is longer than --edge-length (shape kept)
      -> smooth vertex normals of that undisplaced mesh
      -> h = bilinear, repeating sample of the --height image at every vertex
      -> vertex += normal * height_m * (h - midlevel)
      -> optional collapse decimation to --max-tris
      -> glTF binary, +Y up, with smooth normals recomputed from the displaced surface,
         UV0 and tangents; optional JSON --report

The displacement is computed here with numpy, not with Blender's Displace modifier, so
every convention below belongs to this file and tests/test_blender_bake.py checks it.

USAGE (headless; everything after `--` belongs to this script; tested with Blender 4.5 LTS)

    blender -b --factory-startup -P tools/bake_displaced_mesh.py -- \\
        --primitive box --size 2.0,0.9,0.3 --mapping box --texture-size-m 3.0 \\
        --height brick_wall_001_disp_2k.exr --height-m 0.025 --midlevel 1.0 --even-offset \\
        --edge-length 0.007 --max-tris 120000 \\
        --output demo/models/hero_brick_wall.glb --report build/hero_brick_wall.json

    blender -b --factory-startup -P tools/bake_displaced_mesh.py -- \\
        --input rock.glb --mapping uv --uv-scale 2,2 --height rock_height.png \\
        --height-m 0.03 --midlevel 0.5 --edge-length 0.005 --max-tris 80000 \\
        --output build/rock_hero.glb

`... -- --help` lists every option. Exit code: 0 written, 1 error (message on stderr),
2 bad command line.

CONVENTIONS
Space: all coordinates, sizes and report values are in glTF/Godot space: metres, +Y up,
    right-handed. Blender's importers bring .glb/.gltf/.obj into that space (OBJ with the
    usual -Z forward, +Y up), and the exporter writes it back out.
Primitives are centred on x = z = 0 and rest on y = 0. --size X,Y,Z means:
    plane     X by Z at y = 0, facing +Y (Y must be 0)
    box       X by Y by Z, closed
    cylinder  axis +Y, height Y, elliptic cross-section X by Z, capped
    mound     an open surface on y = 0 over an elliptic X by Z footprint, height
              Y * (1 + cos(pi * r)) / 2 at normalised elliptic radius r: flat at the
              rim, a rounded peak Y at the centre (a heap of rubble, sand or earth)
    Their own UV0, used by --mapping uv: every flat face spans 0..1 once and is laid out
    like the box projection below (plane and caps: u along x, v along z); the cylinder
    side has u = angle / 360 degrees (starting at +X, towards +Z) and v = y / Y.
Height: channel R of the image (R = G = B in a grey map), read as data. The tool sets
    the image to Non-Color. This matters: with default settings Blender decodes a 16-bit
    PNG through sRGB (measured error up to 0.29 on a linear ramp). 8-bit images and EXR
    are read raw either way. --remap LO,HI maps LO to 0 and HI to 1 and clamps to 0..1.
    Without --remap the raw value is used as is. The displacement along the unit vertex
    normal is
        d = height_m * (h - midlevel)
    so midlevel is the height that stays on the base surface (the same as Unreal's
    Displacement Center): 0 = relief only outwards, 1 = only inwards, 0.5 = both ways.
Texture coordinates (u, v) are in texture repeats. v runs DOWN the image (glTF, Godot,
    Vulkan: (0, 0) is the top-left corner). Texel centres are at
    ((i + 0.5) / width, (j + 0.5) / height). Sampling is bilinear and repeats.
Mappings use the undisplaced object-space position p = (x, y, z) and S = --texture-size-m:
    planar  (u, v) = (x, z) / S. For a ground prop at the origin, u = world x / S and
            v = world z / S.
    box     each vertex uses the dominant axis of its normal (ties go to X, then Y, then Z):
            X -> (z, y) / S,  Y -> (x, z) / S,  Z -> (x, y) / S.
            There are no sign flips. Seen from outside with +Y up, u runs to the right on
            the +Z and -X faces and to the left on the +X and -Z faces. v runs upwards on
            all four walls, so the image's top row lies at the bottom of each tile.
    uv      (u, v) = UV0 * (U, V) from --uv-scale. A vertex on a UV seam has several
            UVs. It gets the mean of the heights sampled at each of them (the same value
            in a seamless unwrap), which keeps the mesh closed.
Output UV0 holds exactly the coordinates the height was read at. For box mapping they
    are split by each face's own dominant axis, so seams run where that axis changes. A
    material that uses the same texture set with uv1_scale 1 therefore lines up with the
    relief. With --keep-materials, UV0 stays the input's own UV0 because the kept
    materials need it. The sampled coordinates then go to UV1 (glTF TEXCOORD_1,
    Godot UV2).
Normals: the displacement follows smooth, angle-weighted vertex normals of the
    subdivided, undisplaced mesh. Imported vertices at bit-identical positions are welded
    first, so UV seams and hard edges do not tear open. The cost: a vertex on a hard edge
    moves along the averaged normal, and that normal leans away from both faces. The
    vertex therefore sits only d * cos(angle) from each face, which leaves a narrow ridge
    (inward relief) or groove (outward relief) along the edge. --even-offset divides d at
    such vertices by the angle-weighted mean of that cosine: sqrt(2) on a box edge,
    sqrt(3) on a corner, exactly 1 on flat faces and practically 1 on smooth surfaces.
    The exported normals are recomputed, smooth, from the displaced surface.
--border-falloff M fades the displacement to 0 over M metres towards the open border of
    the mesh, measured as the distance to the nearest border vertex. An open patch (the
    mound, a ground piece) then meets the surface it sits on without a gap.

SUBDIVISION: WHY EDGE SPLITTING RATHER THAN LEVELS
Uniform subdivision (levels, or Blender's Subdivide) cuts every edge as often as the
longest edge needs. For the 2.0 x 0.9 x 0.3 m wall at 7 mm, that means 405 segments on
every edge: the 0.3 m edges end up 0.7 mm apart, and the box has 2.0 million triangles
instead of 438,000. Instead, every edge longer than the target is split at its midpoint. Each triangle is
then re-cut by how many of its edges were split: 1 edge gives 2 triangles, 2 give 3
(using the shorter diagonal), 3 give 4. This repeats until no edge is too long. Midpoint
splits keep the shape exactly (no smoothing), and neighbours always agree on shared edges
(no cracks). The primitives are tessellated directly as regular grids and rings whose
longest edge (the cell diagonal) is already within --edge-length, so the refinement
leaves them unchanged. Edge length is measured on the undisplaced surface. Displacement
lengthens edges on slopes, and decimation lengthens them by design.

LIMITS
- Meant for a few hero props. Everything is dense before decimation, and the tool
  refuses to build more than MAX_TRIANGLES triangles (raise --edge-length instead).
- Welding happens only at exactly equal positions. Vertices that are merely close
  stay separate.
- Box mapping on hard edges: an edge vertex reads the height through one face's
  projection, and the two faces' textures do not continue around the edge. Where one
  side reads mortar and the other reads brick, the edge gets a one-vertex notch or bump.
  This is inherent to box projection on a closed mesh.
- Collapse decimation moves vertices off the exact displaced positions (quadric
  placement). The report's displacement range is the signed distance each vertex moved
  along its normal before decimation. With --even-offset it exceeds height_m on creases.
- The output is geometry only by default: no materials, vertex colours or animation.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
import traceback
from dataclasses import dataclass

import bpy
import numpy as np

MAX_TRIANGLES = 12_000_000     # refuse to build meshes beyond this (memory, time)
EDGE_TOLERANCE = 1e-6          # relative slack on the edge-length target (float rounding)
MAX_REFINE_PASSES = 64         # safety cap; about log2(longest edge / target) + 2 are needed
EVEN_OFFSET_LIMIT = 4.0        # --even-offset never scales a displacement by more than this
PRIMITIVES = ("plane", "box", "cylinder", "mound")
# The two coordinates (u, v) each box-projection axis uses: X -> (z, y), Y -> (x, z), Z -> (x, y).
BOX_PLANES = np.array([[2, 1], [0, 2], [0, 1]])
# The normal a grid over those two coordinates gets from (u axis) x (v axis): -X, -Y, +Z.
BOX_PLANE_NORMAL_SIGN = (-1, -1, 1)


class BakeError(Exception):
    """A problem with the inputs, reported as a message without a traceback."""


@dataclass
class TriMesh:
    """Triangles in glTF/Godot space (metres, +Y up), counter-clockwise seen from outside."""
    positions: np.ndarray           # (V, 3) float64
    triangles: np.ndarray           # (T, 3) int64
    corner_uv: np.ndarray | None    # (T, 3, 2) UV0 per triangle corner, v down the image
    material: np.ndarray | None     # (T,) index into the kept materials (--keep-materials)


def log(message: str) -> None:
    print(f"[bake] {message}", flush=True)


# --------------------------------------------------------------------------- arguments

def _numbers(count: int):
    def parse(text: str) -> tuple[float, ...]:
        try:
            values = tuple(float(v) for v in text.split(","))
        except ValueError:
            values = ()
        if len(values) != count or not all(math.isfinite(v) for v in values):
            raise argparse.ArgumentTypeError(f"expected {count} comma-separated numbers, got {text!r}")
        return values
    return parse


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="blender -b --factory-startup -P tools/bake_displaced_mesh.py --",
        description="Bake a tiling height map into real, subdivided and displaced geometry "
                    "(glTF binary). The module docstring documents every convention.")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--input", metavar="FILE", help="base mesh: .glb, .gltf or .obj")
    source.add_argument("--primitive", choices=PRIMITIVES, help="built-in base shape (needs --size)")
    parser.add_argument("--size", type=_numbers(3), metavar="X,Y,Z", help="primitive size in metres")
    parser.add_argument("--height", required=True, metavar="IMAGE",
                        help="height map: EXR, PNG (8/16-bit) or JPG; channel R, read as data")
    parser.add_argument("--height-m", type=float, required=True, metavar="M",
                        help="relief depth: height 0..1 spans this many metres")
    parser.add_argument("--midlevel", type=float, default=0.5,
                        help="height that stays on the base surface: 0 = relief only outwards, "
                             "1 = only inwards (default 0.5)")
    parser.add_argument("--remap", type=_numbers(2), metavar="LO,HI",
                        help="map the raw height LO -> 0 and HI -> 1, clamped, before use")
    parser.add_argument("--mapping", choices=("uv", "box", "planar"), required=True)
    parser.add_argument("--uv-scale", type=_numbers(2), metavar="U,V",
                        help="uv mapping: multiplier on UV0 (default 1,1)")
    parser.add_argument("--texture-size-m", type=float, metavar="M",
                        help="box/planar mapping: metres covered by one repeat of the height map")
    parser.add_argument("--edge-length", type=float, required=True, metavar="M",
                        help="subdivide until no edge of the undisplaced mesh is longer")
    parser.add_argument("--even-offset", action="store_true",
                        help="on creases (box edges), scale the displacement so that it is the full "
                             "depth measured from each adjacent face (no ridge or groove along edges)")
    parser.add_argument("--border-falloff", type=float, default=0.0, metavar="M",
                        help="fade the displacement to 0 towards open mesh borders over this "
                             "distance (default 0 = off)")
    parser.add_argument("--max-tris", type=int, metavar="N",
                        help="collapse-decimate to at most N triangles after displacement")
    parser.add_argument("--keep-materials", action="store_true",
                        help="--input only: keep its materials (UV0 stays the input's, the "
                             "sampled coordinates go to UV1)")
    parser.add_argument("--output", required=True, metavar="FILE.glb")
    parser.add_argument("--report", metavar="FILE.json", help="write a JSON report here")
    args = parser.parse_args(argv)
    _check_args(parser, args)
    return args


def _check_args(parser: argparse.ArgumentParser, a: argparse.Namespace) -> None:
    def need(condition: bool, message: str) -> None:
        if not condition:
            parser.error(message)

    for name in ("height_m", "midlevel", "texture_size_m", "edge_length", "border_falloff"):
        value = getattr(a, name)
        need(value is None or math.isfinite(value), f"--{name.replace('_', '-')} must be a finite number")
    if a.primitive:
        need(a.size is not None, "--primitive needs --size X,Y,Z")
        x, y, z = a.size
        if a.primitive == "plane":
            need(x > 0 and y == 0 and z > 0, "a plane's --size needs X > 0, Y = 0, Z > 0")
        elif a.primitive == "mound":
            need(x > 0 and y >= 0 and z > 0, "a mound's --size needs X > 0, Y >= 0, Z > 0")
        else:
            need(min(a.size) > 0, f"a {a.primitive}'s --size needs X, Y, Z > 0")
        need(not a.keep_materials, "--keep-materials needs --input (primitives have no materials)")
    else:
        need(a.size is None, "--size only applies to --primitive")
    need(a.height_m > 0, "--height-m must be > 0 (inward relief is --midlevel 1)")
    need(0.0 <= a.midlevel <= 1.0, "--midlevel must be within 0..1")
    need(a.remap is None or a.remap[0] < a.remap[1], "--remap LO,HI needs LO < HI")
    if a.mapping == "uv":
        need(a.texture_size_m is None, "--texture-size-m is for box/planar mapping (uv uses --uv-scale)")
        a.uv_scale = a.uv_scale or (1.0, 1.0)
        need(all(s != 0 for s in a.uv_scale), "--uv-scale components must be non-zero")
    else:
        need(a.uv_scale is None, "--uv-scale is for uv mapping (box/planar use --texture-size-m)")
        need(a.texture_size_m is not None and a.texture_size_m > 0,
             f"{a.mapping} mapping needs --texture-size-m > 0")
    need(a.edge_length > 0, "--edge-length must be > 0")
    need(a.border_falloff >= 0, "--border-falloff must be >= 0")
    need(a.max_tris is None or a.max_tris >= 1, "--max-tris must be >= 1")
    need(a.output.lower().endswith(".glb"), "--output must be a .glb file (glTF binary)")


# --------------------------------------------------------------------------- base meshes

def _weld(mesh: TriMesh) -> TriMesh:
    """Merge vertices at bit-identical positions, drop collapsed triangles and unused vertices."""
    unique, inverse = np.unique(mesh.positions + 0.0, axis=0, return_inverse=True)  # +0.0: -0 == 0
    tris = inverse.reshape(-1)[mesh.triangles]
    keep = (tris[:, 0] != tris[:, 1]) & (tris[:, 1] != tris[:, 2]) & (tris[:, 2] != tris[:, 0])
    used, tris = np.unique(tris[keep], return_inverse=True)
    return TriMesh(unique[used], tris.reshape(-1, 3).astype(np.int64),
                   None if mesh.corner_uv is None else mesh.corner_uv[keep],
                   None if mesh.material is None else mesh.material[keep])


def _merge(parts: list[TriMesh]) -> TriMesh:
    offsets = np.cumsum([0] + [len(p.positions) for p in parts[:-1]])
    return _weld(TriMesh(np.concatenate([p.positions for p in parts]),
                         np.concatenate([p.triangles + o for p, o in zip(parts, offsets)]),
                         np.concatenate([p.corner_uv for p in parts]), None))


def _segments(length: float, cell: float) -> int:
    """Fewest equal segments of at most `cell` (ignoring float noise in the ratio)."""
    return max(1, math.ceil(length / cell * (1 - 1e-9)))


def _grid_patch(pos: np.ndarray, uv: np.ndarray, flip: bool) -> TriMesh:
    """Two triangles per cell of an (na, nb) vertex grid. Unflipped, they face
    (a direction) x (b direction)."""
    na, nb = pos.shape[:2]
    idx = np.arange(na * nb).reshape(na, nb)
    v00, v10, v01, v11 = idx[:-1, :-1], idx[1:, :-1], idx[:-1, 1:], idx[1:, 1:]
    tris = np.concatenate([np.stack([v00, v10, v11], -1).reshape(-1, 3),
                           np.stack([v00, v11, v01], -1).reshape(-1, 3)])
    if flip:
        tris = tris[:, ::-1]
    return TriMesh(pos.reshape(-1, 3), tris, uv.reshape(-1, 2)[tris], None)


def _axis_patch(coords: list[np.ndarray], axis: int, side: int, outward: int) -> TriMesh:
    """The face of the box spanned by `coords` that is perpendicular to `axis`, at
    coords[axis][side], facing `outward` (+1/-1). Laid out like the box projection."""
    ua, va = BOX_PLANES[axis]
    a, b = np.meshgrid(coords[ua], coords[va], indexing="ij")
    pos = np.empty(a.shape + (3,))
    pos[..., ua], pos[..., va], pos[..., axis] = a, b, coords[axis][side]
    uv = np.stack([(a - coords[ua][0]) / (coords[ua][-1] - coords[ua][0]),
                   (b - coords[va][0]) / (coords[va][-1] - coords[va][0])], -1)
    return _grid_patch(pos, uv, flip=BOX_PLANE_NORMAL_SIGN[axis] != outward)


def _ring_segments(radius: float, cell: float) -> int:
    """Segments around a rim of this radius with chords <= cell, rounded up to c * 2^q
    (8 <= c < 16) so that the inner rings of a disk can halve it repeatedly."""
    wanted = max(8, math.ceil(2 * math.pi * radius / cell))
    step = 2 ** max(0, int(math.log2(wanted / 8)))
    return math.ceil(wanted / step) * step


def _disk(rx: float, rz: float, cell: float, rim_segments: int, profile, up: bool) -> TriMesh:
    """An elliptic disk (radii rx, rz) lifted to y = profile(r), r = normalised radius.

    Concentric rings sit at equal arc length along the profile, so radial edges stay
    <= cell even on a slope. Going inwards, a ring halves its segment count once its
    chords would drop below half a cell, so the centre is not a dense fan. The rim uses
    exactly the angles of a cylinder side with `rim_segments`, so the two weld.
    """
    big = max(rx, rz)
    r = np.linspace(0.0, 1.0, 4097)
    arc = np.concatenate([[0.0], np.cumsum(np.hypot(np.diff(r) * big, np.diff(profile(r))))])
    rings = _segments(arc[-1], cell)
    radii = np.interp(np.linspace(0.0, arc[-1], rings + 1), arc, r)
    radii[0], radii[-1] = 0.0, 1.0
    counts = [rim_segments]
    for rho in radii[-2:0:-1]:
        m = counts[-1]
        if m % 2 == 0 and m // 2 >= 8 and 2 * math.pi * rho * big / (m // 2) <= cell:
            m //= 2
        counts.append(m)
    counts.reverse()                                  # counts[k - 1] = segments of ring k

    heights = profile(radii)
    positions, starts = [np.array([[0.0, heights[0], 0.0]])], []
    for rho, y, m in zip(radii[1:], heights[1:], counts):
        t = 2 * math.pi * np.arange(m) / m
        starts.append(sum(len(p) for p in positions))
        positions.append(np.stack([rx * rho * np.cos(t), np.full(m, y), rz * rho * np.sin(t)], -1))
    tris = []                                         # all built facing -Y, flipped below if up
    j = np.arange(counts[0])
    tris.append(np.stack([np.zeros_like(j), starts[0] + j, starts[0] + (j + 1) % counts[0]], -1))
    for k in range(1, rings):
        n_in, n_out, s_in, s_out = counts[k - 1], counts[k], starts[k - 1], starts[k]
        j = np.arange(n_in)
        a, b = s_in + j, s_in + (j + 1) % n_in
        if n_out == n_in:
            c, d = s_out + j, s_out + (j + 1) % n_out
            tris += [np.stack([a, c, d], -1), np.stack([a, d, b], -1)]
        else:                                         # n_out == 2 * n_in
            c, mid, d = s_out + 2 * j, s_out + 2 * j + 1, s_out + (2 * j + 2) % n_out
            tris += [np.stack([a, c, mid], -1), np.stack([a, mid, b], -1), np.stack([b, mid, d], -1)]
    tris = np.concatenate(tris)
    if up:
        tris = tris[:, ::-1]
    pos = np.concatenate(positions)
    uv = np.stack([pos[:, 0] / (2 * rx) + 0.5, pos[:, 2] / (2 * rz) + 0.5], -1)
    return TriMesh(pos, tris, uv[tris], None)


def make_primitive(kind: str, size: tuple[float, float, float], edge: float) -> TriMesh:
    """A primitive tessellated so that its longest edge (a cell diagonal) is <= edge."""
    sx, sy, sz = size
    cell = edge / math.sqrt(2.0)          # square-ish cells: two sides <= cell, diagonal <= edge
    if kind in ("plane", "box"):
        coords = [np.linspace(-sx / 2, sx / 2, _segments(sx, cell) + 1),
                  np.linspace(0.0, sy, _segments(sy, cell) + 1),
                  np.linspace(-sz / 2, sz / 2, _segments(sz, cell) + 1)]
        if kind == "plane":
            return _merge([_axis_patch(coords, axis=1, side=0, outward=+1)])
        return _merge([_axis_patch(coords, axis, side, outward)
                       for axis in range(3) for side, outward in ((0, -1), (-1, +1))])
    rx, rz = sx / 2, sz / 2
    segments = _ring_segments(max(rx, rz), cell)
    if kind == "mound":
        return _merge([_disk(rx, rz, cell, segments, lambda r: sy * (1 + np.cos(np.pi * r)) / 2, up=True)])
    # cylinder: the side's last column repeats column 0 (same floats, so it welds) with u = 1
    t = 2 * math.pi * np.arange(segments) / segments
    column = np.arange(segments + 1) % segments
    ys = np.linspace(0.0, sy, _segments(sy, cell) + 1)
    pos = np.empty((segments + 1, len(ys), 3))
    pos[..., 0] = (rx * np.cos(t))[column][:, None]
    pos[..., 1] = ys[None, :]
    pos[..., 2] = (rz * np.sin(t))[column][:, None]
    uv = np.stack(np.meshgrid(np.arange(segments + 1) / segments, ys / sy, indexing="ij"), -1)
    side = _grid_patch(pos, uv, flip=True)    # (angle direction) x (+Y) points inwards
    top = _disk(rx, rz, cell, segments, lambda r: np.full_like(r, sy), up=True)
    bottom = _disk(rx, rz, cell, segments, np.zeros_like, up=False)
    return _merge([side, top, bottom])


def _to_blender(p: np.ndarray) -> np.ndarray:
    """glTF/Godot (x, y, z) -> Blender (x, -z, y); a rotation, so windings are kept."""
    return np.stack([p[:, 0], -p[:, 2], p[:, 1]], axis=1)


def _from_blender(p: np.ndarray) -> np.ndarray:
    """Blender (x, y, z) -> glTF/Godot (x, z, -y)."""
    return np.stack([p[:, 0], p[:, 2], -p[:, 1]], axis=1)


def load_input_mesh(path: str, keep_materials: bool) -> tuple[TriMesh, list]:
    """Import a file, join its mesh objects in world space, weld. Returns the mesh and
    the list of materials that TriMesh.material indexes (empty unless keep_materials)."""
    ext = os.path.splitext(path)[1].lower()
    before = set(bpy.data.objects)
    try:
        if ext in (".glb", ".gltf"):
            bpy.ops.import_scene.gltf(filepath=path)
        elif ext == ".obj":
            bpy.ops.wm.obj_import(filepath=path)       # defaults: -Z forward, +Y up
        else:
            raise BakeError(f"--input must be .glb, .gltf or .obj, not {ext or 'no extension'}")
    except RuntimeError as exc:
        raise BakeError(f"could not import {path}: {exc}") from exc
    imported = [o for o in bpy.data.objects if o not in before]
    depsgraph = bpy.context.evaluated_depsgraph_get()
    materials: list = []
    parts: list[TriMesh] = []
    has_uv = True
    for obj in (o for o in imported if o.type == "MESH"):
        evaluated = obj.evaluated_get(depsgraph)
        me = evaluated.to_mesh()
        try:
            me.calc_loop_triangles()
            count = len(me.loop_triangles)
            if count == 0:
                continue
            co = np.empty(len(me.vertices) * 3)
            me.vertices.foreach_get("co", co)
            verts = np.empty(count * 3, np.int64)
            loops = np.empty(count * 3, np.int64)
            polys = np.empty(count, np.int64)
            me.loop_triangles.foreach_get("vertices", verts)
            me.loop_triangles.foreach_get("loops", loops)
            me.loop_triangles.foreach_get("polygon_index", polys)
            matrix = np.array(obj.matrix_world)
            co = co.reshape(-1, 3) @ matrix[:3, :3].T + matrix[:3, 3]
            verts, loops = verts.reshape(-1, 3), loops.reshape(-1, 3)
            if np.linalg.det(matrix[:3, :3]) < 0:     # mirrored object: keep faces outward
                verts, loops = verts[:, ::-1], loops[:, ::-1]
            corner_uv = None
            if me.uv_layers:
                uv = np.empty(len(me.loops) * 2)
                me.uv_layers[0].data.foreach_get("uv", uv)
                uv = uv.reshape(-1, 2)
                uv[:, 1] = 1.0 - uv[:, 1]             # Blender's v runs up the image
                corner_uv = uv[loops]
            else:
                has_uv = False
            material = None
            if keep_materials:
                slot_materials = [slot.material for slot in obj.material_slots] or [None]
                materials += [m for m in dict.fromkeys(slot_materials) if m not in materials]
                lookup = np.array([materials.index(m) for m in slot_materials], np.int64)
                poly_mat = np.empty(len(me.polygons), np.int64)
                me.polygons.foreach_get("material_index", poly_mat)
                material = lookup[np.clip(poly_mat[polys], 0, len(lookup) - 1)]
            parts.append(TriMesh(_from_blender(co), verts, corner_uv, material))
        finally:
            evaluated.to_mesh_clear()
    for obj in imported:
        bpy.data.objects.remove(obj)
    if not parts:
        raise BakeError(f"{path} contains no triangles")
    offsets = np.cumsum([0] + [len(p.positions) for p in parts[:-1]])
    mesh = _weld(TriMesh(np.concatenate([p.positions for p in parts]),
                         np.concatenate([p.triangles + o for p, o in zip(parts, offsets)]),
                         np.concatenate([p.corner_uv for p in parts]) if has_uv else None,
                         np.concatenate([p.material for p in parts]) if keep_materials else None))
    if len(mesh.triangles) == 0:
        raise BakeError(f"{path} has only degenerate triangles")
    return mesh, materials


# --------------------------------------------------------------------------- subdivision

# Children of a triangle, as slots into (v0, v1, v2, m0, m1, m2), mi = midpoint of edge
# (vi, vi+1). Triangles are first rotated so that a single split edge is edge 0 and a
# single unsplit edge is edge 2. Every child keeps the parent's winding.
_SPLIT_1 = [(0, 3, 2), (3, 1, 2)]
_SPLIT_2_DIAG_V0M1 = [(3, 1, 4), (0, 3, 4), (0, 4, 2)]
_SPLIT_2_DIAG_M0V2 = [(3, 1, 4), (0, 3, 2), (3, 4, 2)]
_SPLIT_3 = [(0, 3, 5), (3, 1, 4), (5, 4, 2), (3, 4, 5)]


def refine(mesh: TriMesh, max_edge: float) -> TriMesh:
    """Split every edge longer than max_edge at its midpoint until none is left (see the
    module docstring). Positions are linear midpoints, so the surface does not change."""
    pos, tris, uv, mat = mesh.positions, mesh.triangles, mesh.corner_uv, mesh.material
    limit = max_edge * (1 + EDGE_TOLERANCE)
    for _ in range(MAX_REFINE_PASSES):
        nxt = np.roll(tris, -1, axis=1)                         # edge k joins corners k, k+1
        split = np.linalg.norm(pos[tris] - pos[nxt], axis=2) > limit
        if not split.any():
            return TriMesh(pos, tris, uv, mat)
        count = split.sum(axis=1)
        n = len(pos)
        keys, inverse = np.unique((np.minimum(tris, nxt) * n + np.maximum(tris, nxt))[split],
                                  return_inverse=True)
        pos = np.concatenate([pos, 0.5 * (pos[keys // n] + pos[keys % n])])
        mid = np.full(tris.shape, -1, np.int64)
        mid[split] = n + inverse.reshape(-1)
        rotation = np.where(count == 1, np.argmax(split, axis=1),
                            np.where(count == 2, (np.argmin(split, axis=1) + 1) % 3, 0))
        order = (np.arange(3) + rotation[:, None]) % 3
        slots = np.concatenate([np.take_along_axis(tris, order, 1), np.take_along_axis(mid, order, 1)], 1)
        if uv is not None:
            ruv = np.take_along_axis(uv, order[:, :, None], 1)
            uv_slots = np.concatenate([ruv, 0.5 * (ruv + np.roll(ruv, -1, axis=1))], 1)
        two = count == 2
        # For two split edges, cut the remaining quad (v0, m0, m1, v2) along its shorter diagonal.
        v0m1_shorter = two.copy()
        v0m1_shorter[two] = (np.linalg.norm(pos[slots[two, 0]] - pos[slots[two, 4]], axis=1)
                             <= np.linalg.norm(pos[slots[two, 3]] - pos[slots[two, 2]], axis=1))
        groups = [(count == 0, [(0, 1, 2)]), (count == 1, _SPLIT_1),
                  (v0m1_shorter, _SPLIT_2_DIAG_V0M1), (two & ~v0m1_shorter, _SPLIT_2_DIAG_M0V2),
                  (count == 3, _SPLIT_3)]
        new_tris, new_uv, new_mat = [], [], []
        for selected, pattern in groups:
            for child in pattern:
                new_tris.append(slots[selected][:, child])
                if uv is not None:
                    new_uv.append(uv_slots[selected][:, child])
                if mat is not None:
                    new_mat.append(mat[selected])
        tris = np.concatenate(new_tris)
        uv = np.concatenate(new_uv) if uv is not None else None
        mat = np.concatenate(new_mat) if mat is not None else None
        if len(tris) > MAX_TRIANGLES:
            raise BakeError(f"subdivision passed {MAX_TRIANGLES:,} triangles; raise --edge-length")
    raise BakeError(f"subdivision did not reach --edge-length {max_edge} in {MAX_REFINE_PASSES} passes")


# --------------------------------------------------------------------------- displacement

def face_normals(pos: np.ndarray, tris: np.ndarray) -> np.ndarray:
    n = np.cross(pos[tris[:, 1]] - pos[tris[:, 0]], pos[tris[:, 2]] - pos[tris[:, 0]])
    length = np.linalg.norm(n, axis=1, keepdims=True)
    return np.divide(n, length, out=np.zeros_like(n), where=length > 0)


def corner_angles(pos: np.ndarray, tris: np.ndarray) -> np.ndarray:
    """(T, 3) interior angle of every triangle corner."""
    angles = np.empty(tris.shape)
    for k in range(3):
        e1 = pos[tris[:, (k + 1) % 3]] - pos[tris[:, k]]
        e2 = pos[tris[:, (k + 2) % 3]] - pos[tris[:, k]]
        angles[:, k] = np.arctan2(np.linalg.norm(np.cross(e1, e2), axis=1), np.einsum("ij,ij->i", e1, e2))
    return angles


def vertex_normals(pos: np.ndarray, tris: np.ndarray) -> np.ndarray:
    """Angle-weighted smooth vertex normals (zero where they cancel out)."""
    unit, angles = face_normals(pos, tris), corner_angles(pos, tris)
    acc = np.zeros_like(pos)
    for k in range(3):
        for c in range(3):
            acc[:, c] += np.bincount(tris[:, k], weights=unit[:, c] * angles[:, k], minlength=len(pos))
    length = np.linalg.norm(acc, axis=1, keepdims=True)
    return np.divide(acc, length, out=np.zeros_like(acc), where=length > 1e-12)


def even_offset_scale(pos: np.ndarray, tris: np.ndarray, normals: np.ndarray) -> np.ndarray:
    """Per-vertex 1 / (angle-weighted mean cosine between the vertex normal and its faces).

    On a crease the averaged normal leans away from both faces. Moving a vertex d along it
    moves it only d * cos from each face, while the faces' interior vertices move the full
    d. That leaves a ridge (inward relief) or a groove (outward relief) along every edge;
    a 90-degree box edge loses 29 % of d. This factor restores the full perpendicular
    offset: sqrt(2) on a box edge, sqrt(3) on a box corner, 1 on flat and smooth surfaces.
    It is clamped to EVEN_OFFSET_LIMIT for near-degenerate spikes.
    """
    unit, angles = face_normals(pos, tris), corner_angles(pos, tris)
    weight, weighted_cos = np.zeros(len(pos)), np.zeros(len(pos))
    for k in range(3):
        cos = np.einsum("ij,ij->i", normals[tris[:, k]], unit)
        weight += np.bincount(tris[:, k], angles[:, k], len(pos))
        weighted_cos += np.bincount(tris[:, k], angles[:, k] * cos, len(pos))
    mean_cos = np.divide(weighted_cos, weight, out=np.ones(len(pos)), where=weight > 0)
    return 1.0 / np.clip(mean_cos, 1.0 / EVEN_OFFSET_LIMIT, 1.0)


def load_height_map(path: str) -> np.ndarray:
    """Channel R as float64 (rows, cols), row 0 = the TOP of the image."""
    try:
        image = bpy.data.images.load(path, check_existing=False)
    except RuntimeError as exc:
        raise BakeError(f"cannot read height map {path}: {exc}") from exc
    try:
        # Height is data. Set before the pixels are first read: Blender otherwise decodes
        # 16-bit PNG/TIFF through sRGB. alpha NONE: no premultiplication by an alpha channel.
        image.colorspace_settings.name = "Non-Color"
        image.alpha_mode = "NONE"
        if not image.colorspace_settings.is_data:
            raise BakeError("Blender did not accept the Non-Color setting for the height map")
        width, height = image.size
        if width == 0 or height == 0:
            raise BakeError(f"{path} is empty or not an image Blender can decode")
        pixels = np.empty(len(image.pixels), np.float32)
        image.pixels.foreach_get(pixels)
        return pixels.reshape(height, width, -1)[::-1, :, 0].astype(np.float64)  # Blender: bottom row first
    finally:
        bpy.data.images.remove(image)


def sample_bilinear_repeat(image: np.ndarray, uv: np.ndarray) -> np.ndarray:
    """Bilinear, repeating lookup at (u, v) with v down the image; texel centres at (i + 0.5) / size."""
    rows, cols = image.shape
    x = uv[:, 0] * cols - 0.5
    y = uv[:, 1] * rows - 0.5
    x0, y0 = np.floor(x), np.floor(y)
    fx, fy = x - x0, y - y0
    x0 = x0.astype(np.int64) % cols
    y0 = y0.astype(np.int64) % rows
    x1, y1 = (x0 + 1) % cols, (y0 + 1) % rows
    top = image[y0, x0] * (1 - fx) + image[y0, x1] * fx
    bottom = image[y1, x0] * (1 - fx) + image[y1, x1] * fx
    return top * (1 - fy) + bottom * fy


def _box_project(pos: np.ndarray, axis: np.ndarray, size: float) -> np.ndarray:
    return np.take_along_axis(pos, BOX_PLANES[axis], axis=1) / size


def sample_heights(args, mesh: TriMesh, normals: np.ndarray, image: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Per-vertex height (after --remap) and the per-corner coordinates it was read at."""
    pos, tris = mesh.positions, mesh.triangles
    if args.mapping == "uv":
        corner_uv = mesh.corner_uv * np.array(args.uv_scale)
        per_corner = sample_bilinear_repeat(image, corner_uv.reshape(-1, 2))
        corners = tris.reshape(-1)
        h = np.bincount(corners, per_corner, len(pos)) / np.bincount(corners, minlength=len(pos))
    elif args.mapping == "planar":
        vertex_uv = pos[:, [0, 2]] / args.texture_size_m
        h = sample_bilinear_repeat(image, vertex_uv)
        corner_uv = vertex_uv[tris]
    else:
        h = sample_bilinear_repeat(image, _box_project(pos, np.argmax(np.abs(normals), axis=1),
                                                       args.texture_size_m))
        face_axis = np.repeat(np.argmax(np.abs(face_normals(pos, tris)), axis=1), 3)
        corner_uv = _box_project(pos[tris.reshape(-1)], face_axis, args.texture_size_m).reshape(-1, 3, 2)
    if args.remap:
        lo, hi = args.remap
        h = np.clip((h - lo) / (hi - lo), 0.0, 1.0)
    return h, corner_uv


def border_weights(pos: np.ndarray, tris: np.ndarray, falloff: float) -> np.ndarray | None:
    """smoothstep(distance to the nearest open-border vertex / falloff); None if closed."""
    from mathutils.kdtree import KDTree

    a, b = tris.reshape(-1), np.roll(tris, -1, axis=1).reshape(-1)
    keys, uses = np.unique(np.minimum(a, b) * len(pos) + np.maximum(a, b), return_counts=True)
    edges = keys[uses == 1]
    border = np.unique(np.concatenate([edges // len(pos), edges % len(pos)]))
    if len(border) == 0:
        return None
    tree = KDTree(len(border))
    for i, p in enumerate(pos[border].tolist()):
        tree.insert(p, i)
    tree.balance()
    distance = np.array([tree.find(p)[2] for p in pos.tolist()])
    t = np.clip(distance / falloff, 0.0, 1.0)
    return t * t * (3 - 2 * t)


# --------------------------------------------------------------------------- Blender side

def build_object(name: str, pos: np.ndarray, tris: np.ndarray, uv_layers: list,
                 material: np.ndarray | None, materials: list):
    """A smooth-shaded Blender mesh object from glTF-space arrays; uv_layers = [(name, corner_uv)]."""
    me = bpy.data.meshes.new(name)
    me.vertices.add(len(pos))
    me.vertices.foreach_set("co", _to_blender(pos).astype(np.float32).ravel())
    me.loops.add(tris.size)
    me.loops.foreach_set("vertex_index", tris.astype(np.int32).ravel())
    me.polygons.add(len(tris))
    me.polygons.foreach_set("loop_start", np.arange(0, tris.size, 3, dtype=np.int32))
    for layer_name, corner_uv in uv_layers:
        uv = corner_uv.reshape(-1, 2).copy()
        uv[:, 1] = 1.0 - uv[:, 1]                     # to Blender's v-up convention
        me.uv_layers.new(name=layer_name).data.foreach_set("uv", uv.astype(np.float32).ravel())
    for mat in materials:
        me.materials.append(mat)
    if material is not None:
        me.polygons.foreach_set("material_index", material.astype(np.int32))
    me.update(calc_edges=True)
    if me.validate(verbose=False):
        log("warning: Blender repaired the mesh (degenerate or duplicate faces removed)")
    me.shade_smooth()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def _triangle_count(me) -> int:
    sizes = np.empty(len(me.polygons), np.int64)
    me.polygons.foreach_get("loop_total", sizes)
    return int((sizes - 2).sum())


def decimate(obj, max_tris: int) -> float:
    """Collapse-decimate in place to <= max_tris triangles; returns the ratio used."""
    have = _triangle_count(obj.data)
    modifier = obj.modifiers.new("decimate", "DECIMATE")
    modifier.decimate_type = "COLLAPSE"
    modifier.use_collapse_triangulate = True
    ratio = max_tris / have
    for _ in range(8):                        # the result is close to ratio * have, not exact
        modifier.ratio = ratio
        depsgraph = bpy.context.evaluated_depsgraph_get()
        evaluated = obj.evaluated_get(depsgraph)
        got = _triangle_count(evaluated.data)
        if got <= max_tris:
            break
        ratio *= 0.999 * max_tris / got
    else:
        raise BakeError(f"decimation could not get below --max-tris {max_tris} (last {got})")
    mesh = bpy.data.meshes.new_from_object(evaluated, preserve_all_data_layers=True, depsgraph=depsgraph)
    obj.modifiers.remove(modifier)
    old, obj.data = obj.data, mesh
    bpy.data.meshes.remove(old)
    mesh.shade_smooth()
    return ratio


def export_glb(obj, path: str, keep_materials: bool) -> None:
    for other in bpy.context.scene.objects:
        other.select_set(other is obj)
    bpy.context.view_layer.objects.active = obj
    try:
        bpy.ops.export_scene.gltf(
            filepath=path, export_format="GLB", use_selection=True, export_yup=True,
            export_apply=False, export_normals=True, export_tangents=True, export_texcoords=True,
            export_materials="EXPORT" if keep_materials else "NONE", export_vertex_color="NONE",
            export_attributes=False, export_extras=False, export_cameras=False, export_lights=False,
            export_animations=False, export_skins=False, export_morph=False)
    except RuntimeError as exc:
        raise BakeError(f"glTF export to {path} failed: {exc}") from exc


# --------------------------------------------------------------------------- main

def _max_edge(pos: np.ndarray, tris: np.ndarray) -> float:
    return float(np.linalg.norm(pos[tris] - pos[np.roll(tris, -1, axis=1)], axis=2).max())


def run(args: argparse.Namespace) -> dict:
    for label, path in (("--input", args.input), ("--height", args.height)):
        if path is not None and not os.path.isfile(path):
            raise BakeError(f"{label} file not found: {path}")
    for obj in list(bpy.data.objects):                # --factory-startup's cube, camera, light
        bpy.data.objects.remove(obj)
    warnings: list[str] = []

    if args.primitive:
        base = make_primitive(args.primitive, args.size, args.edge_length)
        materials: list = []
        log(f"{args.primitive} {args.size}: {len(base.triangles):,} triangles at the target edge length")
    else:
        base, materials = load_input_mesh(os.path.abspath(args.input), args.keep_materials)
        log(f"{args.input}: {len(base.triangles):,} triangles, {len(base.positions):,} welded vertices")
    if args.mapping == "uv" and base.corner_uv is None:
        raise BakeError("--mapping uv needs UVs, but the input has no UV map")
    mesh = refine(base, args.edge_length)
    max_edge = _max_edge(mesh.positions, mesh.triangles)
    log(f"subdivided: {len(mesh.triangles):,} triangles, longest edge {max_edge * 1000:.2f} mm")

    normals = vertex_normals(mesh.positions, mesh.triangles)
    no_normal = int((~normals.any(axis=1)).sum())
    if no_normal:
        warnings.append(f"{no_normal} vertices have no defined normal and are not displaced")
    image = load_height_map(os.path.abspath(args.height))
    raw_range = (float(image.min()), float(image.max()))
    if args.remap is None and (raw_range[0] < 0 or raw_range[1] > 1):
        warnings.append(f"raw height range {raw_range} is outside 0..1; consider --remap")
    h, sampled_uv = sample_heights(args, mesh, normals, image)
    offset = args.height_m * (h - args.midlevel)
    if args.even_offset:
        offset *= even_offset_scale(mesh.positions, mesh.triangles, normals)
    if args.border_falloff > 0:
        weight = border_weights(mesh.positions, mesh.triangles, args.border_falloff)
        if weight is None:
            warnings.append("--border-falloff has no effect: the mesh has no open border")
        else:
            offset *= weight
    displaced = mesh.positions + offset[:, None] * normals
    log(f"displacement {offset.min() * 1000:+.2f} .. {offset.max() * 1000:+.2f} mm")

    if args.keep_materials and mesh.corner_uv is not None:
        uv_layers = [("UVMap", mesh.corner_uv), ("SampledUV", sampled_uv)]
    else:
        uv_layers = [("UVMap", sampled_uv)]
    name = os.path.splitext(os.path.basename(args.output))[0]
    obj = build_object(name, displaced, mesh.triangles, uv_layers, mesh.material, materials)
    ratio = None
    if args.max_tris is not None and len(mesh.triangles) > args.max_tris:
        ratio = decimate(obj, args.max_tris)
    out_tris = _triangle_count(obj.data)
    log(f"output: {out_tris:,} triangles" + (f" (decimation ratio {ratio:.4f})" if ratio else ""))

    out_path = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    export_glb(obj, out_path, args.keep_materials)
    co = np.empty(len(obj.data.vertices) * 3)
    obj.data.vertices.foreach_get("co", co)
    final = _from_blender(co.reshape(-1, 3))
    for warning in warnings:
        print(f"[bake] warning: {warning}", file=sys.stderr, flush=True)
    log(f"wrote {out_path} ({os.path.getsize(out_path):,} bytes)")
    return {
        "tool": "tools/bake_displaced_mesh.py",
        "blender": bpy.app.version_string,
        "space": "glTF/Godot: metres, +Y up",
        "base": ({"primitive": args.primitive, "size_m": list(args.size)} if args.primitive
                 else {"input": os.path.abspath(args.input)}),
        "height_map": {"path": os.path.abspath(args.height), "width": image.shape[1],
                       "height": image.shape[0], "channel": "R", "colorspace": "Non-Color",
                       "raw_min": raw_range[0], "raw_max": raw_range[1]},
        "parameters": {"height_m": args.height_m, "midlevel": args.midlevel,
                       "remap": list(args.remap) if args.remap else None, "mapping": args.mapping,
                       "uv_scale": list(args.uv_scale) if args.uv_scale else None,
                       "texture_size_m": args.texture_size_m, "edge_length_m": args.edge_length,
                       "even_offset": args.even_offset, "border_falloff_m": args.border_falloff,
                       "max_tris": args.max_tris,
                       "keep_materials": args.keep_materials},
        "triangles": {"base": len(base.triangles), "subdivided": len(mesh.triangles), "output": out_tris},
        "vertices": {"subdivided": len(mesh.positions), "output": len(final)},
        "max_edge_m_subdivided": max_edge,
        "displacement_m": {"min": float(offset.min()), "max": float(offset.max())},
        "decimation_ratio": ratio,
        "bounding_box_m": {"min": final.min(axis=0).tolist(), "max": final.max(axis=0).tolist()},
        "output": {"path": out_path, "bytes": os.path.getsize(out_path)},
        "warnings": warnings,
    }


def main() -> int:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = parse_args(argv)
    try:
        report = run(args)
    except BakeError as exc:
        print(f"bake_displaced_mesh: error: {exc}", file=sys.stderr, flush=True)
        return 1
    if args.report:
        path = os.path.abspath(args.report)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(report, fh, indent=2)
        log(f"report {path}")
    return 0


if __name__ == "__main__":
    try:
        code = main()
    except SystemExit:
        raise
    except BaseException:                   # Blender would otherwise exit 0 after a traceback
        traceback.print_exc()
        code = 1
    sys.exit(code)
