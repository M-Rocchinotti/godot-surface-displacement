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
- **Stage 1b: done.** The per-material layered surface material (`gads_core.gdshaderinc`'s
  `GADS_LAYERED` path) is converted from the fixed `layer1_`/`layer2_` `sampler2D` uniforms to a
  `sampler2DArray` N-layer system (`layer_albedo`/`layer_normal`/`layer_orm`/`layer_height` plus
  `layer_*[]` scalar arrays sized by `#define GADS_LAYERED_LAYERS 3`), lifting the cap from base + 2
  to **base + 3 = 4** (matching the field's `GADS_FIELD_LAYERS`) and dropping the layered fragment's
  sampler count so a four-layer material fits WebGL's 16-unit limit. `GADSMaterials.combine_layers`
  and `create_layered` build the arrays with `build_layer_array` and linearise each layer's tint as
  the field does (an array uniform cannot carry `source_color`); the source height textures are kept
  as the `gads_layer_heights` metadata for the CPU bake.
  - **Masks moved off varyings.** The two-layer cap was a varying-budget limit: the per-layer masks
    rode a `vec2 gads_layer_masks` vertex→fragment varying. They are now computed per fragment from
    `COLOR` (a fragment built-in) and the slope band (`gads_layer_mask`), so that varying is gone;
    the relief argument grows from `vec3` to `vec4` (scale + three masks) and the self-shadow still
    carries it in `gads_ss_arg` (one varying) because `light()` cannot read `COLOR`. Net: one fewer
    varying component than before, so every variant stays within the Compatibility/Mobile budget.
  - **Bake cap unchanged.** The native tessellator keeps its two-extra-layer limit (`Layer
    layers[2]`), so a baked mesh bakes the first two extra layers; the render path draws all three.
    The terrain's `MAX_LAYERS` is lifted to 4, but its splat/weights still drive two extra layers
    (R, G) — a third needs the control map (Stage 2) or hand-painted vertex colour.
  - The full suite (`tests/run_all.py`) stays green on all renderers; the layered demo shot (Hills)
    moved only 0.0001 mean (limit 0.003) from the array repacking, so the baseline is unchanged.
- **Stage 3 is being done in increments; 3a (region foundation) is done.** The terrain now
  partitions its maps — the heightmap source (`_src`), the splat source (`_splat`), the holes and
  the per-vertex caches (`_heights`/`_w1`/`_w2`) — into a sparse grid of fixed-size regions, keyed
  by integer `Vector2i`, set by the exported `region_size` (metres, rounded up to a whole number of
  chunks; default 1024 m). `GADSTerrain3D._regions` is the per-region source of truth and
  `get_region_grid()` reports the grid.
  - **No behaviour change — foundation only.** Every region stays resident, so the chunks, collision,
    detail field, editing, save and load are unchanged. While resident, the flat map arrays stay as
    the coalesced hot-path view (the chunk builder, the native mesher, the collision shape and the
    editing tools read and write them exactly as before); `_region_sync` re-partitions the store from
    that view after every change, so store and view never diverge. `_region_coalesce` reassembles a
    map from its regions (the inverse of the split) for the view, the tests and 3c's per-region save.
  - **Single-region fast path.** With the 1024 m default every demo and test terrain (≤ 96 m) is one
    region, so a region simply references the whole map array — no copy, byte-identical. A terrain
    wider than `region_size` tiles into `get_region_grid()` regions, the last on each axis partial.
  - **Addressing toward 16k.** Regions are keyed by integer coordinate (`_region_of_vertex`,
    `_region_vertex_rect`, `_region_slice`), not assumed to start at the origin, so 3b can load and
    free regions by distance and 3c can save each region to its own file.
  - The full suite (`tests/run_all.py`) stays green on all renderers (15/15); a new terrain test
    (`partitions_into_regions`) checks the grid, that reads match tiled or not, that an edit touches
    only its region, and that the regions coalesce back to the whole map. The visual-regression
    baselines are unchanged (every scene is a single region).
- **Stage 3b: per-region persistence is done.** A terrain's editable maps can be saved one file
  per region (`GADSTerrainRegion`, `addons/gads/terrain/gads_terrain_region.gd`) and loaded back:
  `GADSTerrain3D.save_regions(dir)` writes a `region_<x>_<y>.res` per region (header: coord, region
  grid, size, spacing, chunk quads, each whole map's dimensions; body: that region's height/splat/
  holes tile), and `load_regions(dir)` restores the grid from the header, reassembles the whole maps
  through `_region_coalesce` and rebuilds. A terrain loaded from region files is byte-identical to
  the same terrain imported from a whole heightmap/splat (proven by `persists_regions_to_files`).
  It is additional to the whole-texture import and `save_edited_maps` (those are untouched), every
  region still stays resident, and building is unchanged. This is the persistence primitive Stage 4
  uses to keep near regions and free far ones. Full suite 15/15; visual-regression baselines
  unchanged.
  - **Remaining for the region system → Stage 4:** load/free region *data* (and their chunks and
    collision) by distance for the actual 16k memory win, with cross-region border handling.
