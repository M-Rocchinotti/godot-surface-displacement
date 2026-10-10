# Terrain-engine parity plan

Goal: bring GADS's terrain to feature parity with Terrain3D on everything a terrain engine needs
except maturity (community, shipped-game track record, which only time earns). Built in staged,
independently-tested increments on the `terrain-engine` branch; `master` stays at the stable v1.0.0
and each stage merges back when solid.

## Why staged

Terrain3D is a mature C++ engine; matching it (especially 16k region streaming) is a multi-week,
multi-stage effort. Each stage below lands tested and useful on its own, so progress is real even
between sessions.

## Stages

1. **Texture-array layers (keystone).** Replace the per-layer sampler arrays (`sampler2D layer_x[N]`,
   N units) with `sampler2DArray` (one unit, any depth). Lifts the layer cap well past 3 and drops
   the fragment-sampler count under WebGL's 16-unit limit, so multi-layer terrain renders on the web.
   - 1a. The detail field (`gads_field.gdshaderinc`) + its GDScript upload.
   - 1b. The layered surface material (`gads_core.gdshaderinc` layer1_/layer2_) used by terrain chunks.
   - Dynamic `sampler2DArray` indexing is legal on all three renderers, so the unrolled
     `GADS_LAYER_LOD`/`GADS_LAYER_GRAD` branch macros collapse to a direct array lookup.
2. **Splat / control map.** Per-texel layer selection + blend (a control texture), so many layers can
   be painted, replacing/augmenting the vertex-colour + ground-code masks.
3. **Region system.** Divide the terrain into fixed-size regions (e.g. 1k) addressed in a sparse grid,
   so a 16k world is a set of loaded regions, not one mesh.
4. **Streaming + LOD + collision at scale.** Load/free regions and their collision by distance; region
   LODs (the field clipmap already handles near-camera detail).
5. **Heightmap import.** raw / r16 / exr region import (WorldMachine, Unreal, Unity, HTerrain).
6. **Paint-workflow polish.** Brush painting of height, layers, holes, colour and wetness at scale.

Not code: **maturity** — shipped projects, community, longevity.

## Status

- **Stage 1a: done.** Layer samplers (field + pebble shaders) and the `GADS_LAYER_LOD/GRAD` macros
  are converted to `sampler2DArray`; the GDScript builds the arrays via
  `GADSMaterials.build_layer_array` (height `FORMAT_RF`, colour `FORMAT_RGBA8`, resized to the
  largest layer). Shaders compile on all renderers, the sampler count fits WebGL, and the full suite
  (`tests/run_all.py`) is green on all renderers, including the two "field shades like the parallax
  ground" checks (0.56 % / 0.19 % mean luminance, limits 1 % / 2 %).
  - **Shading fix (was the open issue).** The drift was *not* a mip colour-space problem. Measured:
    Godot's importer averages sRGB albedo mips in the *stored* (gamma) space, matching a plain
    `generate_mipmaps` to within 0.1 % — so building linear-light albedo mips made it *worse*, and
    the drift was worst *near* the camera (strong relief), not in the distance. Real cause: `master`
    bound the same imported textures as the ground (matched to ~0.15 %); the array rebuild called
    `generate_mipmaps`, which *overwrote the importer's mip chain* — including the renormalized
    normal-map mips — with plain averages, flattening the normals and brightening the field. Fix:
    `build_layer_array` now keeps each source's imported mip chain, only (re)building mips for a
    fill slice or a resized layer.
  - **Caching fix (second regression from the conversion).** `master` passed the layers as an
    `Array[Texture2D]` (compared by value), so re-applying unchanged layers was a no-op; a freshly
    built `Texture2DArray` is a new object every time, so the editor's 30-frame `sync_layers`
    rebuilt (decompress + mipmaps) and re-uploaded all four arrays each time. `_apply_layers` now
    caches the arrays per channel keyed by the source textures (`_layer_array`).
