#!/usr/bin/env python
"""Rebuild addons/gads/render/textures/gads_dfg_lut.exr.

The self-shadowing variants replace Godot's direct-light BRDF with a custom light() function,
and Godot scales direct specular light by a multiple-scattering energy compensation
1 + f0 * (1 / E - 1), where E comes from its DFG look-up texture (the green channel written by
servers/rendering/renderer_rd/shaders/forward_clustered/integrate_dfg.glsl, Godot 4.7.2). A
shader cannot read the engine's texture, so this script repeats that integration exactly (same
Hammersley points, same importance sampling, same Smith-Schlick G with k = roughness^2 / 2) and
stores E(n.v, roughness) at the same 128 x 128 texel centres, as half floats like the engine's
rgba16f image. Rows are roughness (row y holds roughness (y + 0.5) / 128), columns are n.v.

    python tools/make_dfg_lut.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from exr import write_exr  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "addons" / "gads" / "render" / "textures" / "gads_dfg_lut.exr"
SAMPLE_COUNT = 1024
SIZE = 128


def radical_inverse_vdc(bits: np.ndarray) -> np.ndarray:
    b = bits.astype(np.uint32)
    b = (b << np.uint32(16)) | (b >> np.uint32(16))
    b = ((b & np.uint32(0x55555555)) << np.uint32(1)) | ((b & np.uint32(0xAAAAAAAA)) >> np.uint32(1))
    b = ((b & np.uint32(0x33333333)) << np.uint32(2)) | ((b & np.uint32(0xCCCCCCCC)) >> np.uint32(2))
    b = ((b & np.uint32(0x0F0F0F0F)) << np.uint32(4)) | ((b & np.uint32(0xF0F0F0F0)) >> np.uint32(4))
    b = ((b & np.uint32(0x00FF00FF)) << np.uint32(8)) | ((b & np.uint32(0xFF00FF00)) >> np.uint32(8))
    return b.astype(np.float64) * 2.3283064365386963e-10


def directional_albedo(n_dot_v: float, roughness: float, xi: np.ndarray) -> float:
    """The B term of integrate_brdfs(): mean of G_Vis over GGX-importance-sampled directions."""
    v = np.array([np.sqrt(1.0 - n_dot_v * n_dot_v), 0.0, n_dot_v])
    a = roughness * roughness
    phi = 2.0 * np.pi * xi[:, 0]
    cos_t = np.sqrt((1.0 - xi[:, 1]) / (1.0 + (a * a - 1.0) * xi[:, 1]))
    sin_t = np.sqrt(1.0 - cos_t * cos_t)
    # importance_sample_ggx() takes H from its tangent frame to world space; for N = +Z its frame
    # (tangent = normalize(cross((1, 0, 0), N)) = -Y, bitangent = cross(N, tangent) = +X) turns
    # (x, y, z) into (y, -x, z). The integral does not change, the 1024-sample estimate does.
    h = np.stack([np.sin(phi) * sin_t, -np.cos(phi) * sin_t, cos_t], axis=1)
    h /= np.linalg.norm(h, axis=1)[:, None]
    v_dot_h_raw = h @ v
    l = 2.0 * v_dot_h_raw[:, None] * h - v
    l /= np.linalg.norm(l, axis=1)[:, None]
    n_dot_l = np.clip(l[:, 2], 0.0, 1.0)
    n_dot_h = np.clip(h[:, 2], 0.0, 1.0)
    v_dot_h = np.clip(v_dot_h_raw, 0.0, 1.0)
    k = roughness * roughness / 2.0

    def schlick_ggx(x: np.ndarray | float) -> np.ndarray | float:
        return x / (x * (1.0 - k) + k)

    g = schlick_ggx(np.clip(n_dot_v, 0.0, 1.0)) * schlick_ggx(n_dot_l)
    mask = n_dot_l > 0.0
    g_vis = g[mask] * v_dot_h[mask] / (n_dot_h[mask] * n_dot_v)
    return float(g_vis.sum() / SAMPLE_COUNT)


def main() -> int:
    i = np.arange(SAMPLE_COUNT, dtype=np.uint32)
    xi = np.stack([i.astype(np.float64) / SAMPLE_COUNT, radical_inverse_vdc(i)], axis=1)
    lut = np.zeros((SIZE, SIZE), dtype=np.float32)
    for y in range(SIZE):
        roughness = (y + 0.5) / SIZE
        for x in range(SIZE):
            lut[y, x] = directional_albedo((x + 0.5) / SIZE, roughness, xi)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    write_exr(OUT, {"R": lut}, half=True, compression="zip")
    print(f"wrote {OUT.relative_to(ROOT)}: E in [{lut.min():.4f}, {lut.max():.4f}]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
