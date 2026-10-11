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
- **Stage 4a: sparse region-DATA residency is done.** A region-file-backed streaming terrain
  (`load_regions` on a terrain with `stream_radius > 0` and per-vertex maps) now keeps only the
  regions near the camera in memory: `GADSTerrain3D._regions` holds just the resident tiles, loaded
  from each `region_<x>_<y>.res` by distance (the engine's threaded loader, on a background thread)
  and freed when the camera leaves. A 16k world costs a bounded handful of region tiles, not the
  whole ~1 GB map — the actual large-world memory win. (`get_resident_regions()` reports the set.)
  - **Chunk-aligned regions.** The region split (`_axis_bound`, replacing 3a's near-equal `_split`)
    snaps region boundaries on the vertex grid to whole chunks (`_region_quads` quads, the last
    region partial), so every chunk lies within one region and a region's tile is a whole-chunk
    block. An off-grid map (a whole-texture import's heightmap, a low-res splat) keeps the near-equal
    split and stays fully resident, so 3a/3b are byte-identical (the geometries coincide).
  - **Borders (the apron).** Residency keeps each near region's eight neighbours resident too, so a
    chunk at a region edge reads its one-texel apron (heights for bilinear/normals, splat for
    weights) straight from the neighbour region's resident tile — identical to the whole terrain, no
    seam. A chunk starts only once its region and that ring are resident.
  - **Threading.** `_regions` is touched only on the main thread (loads installed, far regions
    freed). Each chunk-build / ground-window worker task gets an immutable snapshot (`_regions`
    shallow copy) and reads only that, so freeing a region never races a task and a freed tile stays
    alive for any task still holding it. `_sample_source`/`_grid_weights`/`_grid_h`/`_height_local`/
    `_weights_at` and the GDScript chunk+ground builders take an optional `store` (the snapshot);
    the whole-texture (non-region-file) case keeps its native fast path untouched.
  - The full suite stays 15/15 on all renderers; a new terrain test
    (`region_data_streams_by_distance`) builds a 256 m, 64-region, streaming terrain, moves the
    camera corner-to-corner and asserts only near regions are resident (far freed and reloaded on
    approach), heights/weights near the camera match a full-resident reference (border-correct across
    a region boundary), and resident tile memory is ~12 % of the whole map. Visual-regression
    baselines unchanged (no scene uses a sparse terrain).
- **Stage 4b: collision streams by distance (Stage 4 core complete).** A streaming terrain already
  builds one collision shape per streamed chunk and frees it with the chunk (no whole-terrain height
  shape); on a region-file-backed terrain those shapes are built from the resident region tiles, so
  collision costs the same bounded ring the data and chunks do. A new terrain test
  (`collision_streams_by_distance`) confirms it: a 128 m, 16-region streaming terrain builds one
  shape per chunk at the camera's corner (none at the far corner, no whole shape), and flying across
  rebuilds them at the far corner and frees the near ones. With chunk mesh LODs (and the detail
  field for near-camera relief) already streaming per 4a, Stage 4's core — load/free of region data,
  chunks and collision by distance, with LOD at scale — is complete; full suite 15/15.
  - **Deliberately deferred (beyond the AA parity bar; not maturity):** coarser region-DATA mip-LOD
    for distant regions (a further memory optimization — near detail is the field's job and the mesh
    already LODs per chunk); a native (rather than GDScript) chunk build for the sparse path (a
    speed optimization); and sculpting/painting a sparse streaming terrain in place (editing a 16k
    world's loaded region). These are optimizations/extensions, not required for the streaming a
    large world needs, which Stages 3–4 now provide.
- **Stage 5: heightmap region import is done.** The single-file loader (`GADSHeightImport`: 16-bit
  RAW/r16 with endianness, 16-bit PNG, EXR and the rest through the engine, with remap and
  displacement-aware mipmaps) now bridges to the region system: `import_as_regions(height_path,
  out_dir, params)` loads a large heightmap (World Machine / Unreal / Unity / HTerrain), fits it to
  the terrain's vertex grid off-tree (`GADSTerrain3D.build_region_store`, the data-only subset of
  rebuild — no chunks, collision or field, so the whole world's geometry is never built or held) and
  writes one `region_<x>_<y>.res` per region (`save_regions`), which a streaming terrain then loads
  sparsely (Stage 4a). `import_tiles_as_regions` + `assemble_tiles` do the same from a grid of tile
  files (`<name>_<col>_<row>.<ext>`, with an `overlap` option). The per-tool sizing/endianness/scale
  conventions are documented in the code and the README. A region set built from an off-grid source
  reads back through the grid exactly as the terrain would sample that source directly (a pre-tiled
  set imports byte-identically to the equivalent whole map). New terrain tests
  (`imports_heightmaps_as_regions`) import a synthetic `.r16` and `.exr` and a 2x2 tiled set and check
  the heights match the source within 16-bit precision and that tiled == whole. Full suite 15/15.
- **Stage 6: per-texel colour and wetness painting is done (plan complete).** The last paint targets
  — a per-texel surface COLOUR (an albedo tint) and WETNESS — join height, layers and holes. A single
  optional RGBA map (the surface-paint map) is sampled by world XZ, the twin of the Stage 2 control
  map: RGB a colour tint multiplied onto the blended albedo (`albedo *= tint`), A an extra wetness fed
  into the existing surface effects as a `max` with the global weather (`gads_surface_effects`'
  new `extra_wetness`, and the field's `e.wetness`). It is a runtime branch inside the `GADS_LAYERED`
  path (`gads_core.gdshaderinc` + the field `gads_field.gdshaderinc`), a no-op when
  `surface_paint_rect.z <= 0` (unbound), so unpainted terrains, every non-layered / whole-texture case
  and the variant table are byte-identical; the extra sampler (one unit, `source_color` so the tint
  reads as linear and the wetness stays in A) keeps the layered fragment within WebGL's 16. The field
  binds the same texture and rect (`GADSDisplacementField3D.set_surface_paint`), so the near-camera
  relief tints exactly like the chunks across a painted spot (no seam), as Stage 2's control map does.
  - **Paint API + tools.** `GADSTerrain3D.paint_colour(world, radius, Color, strength, falloff)` and
    `paint_wetness(world, radius, amount, strength, falloff)` paint the surface map with the same
    brush the layer tools use (`paint_layer`'s falloff), making it an editable map of one RGBA8 texel
    per vertex (`surfacemap`, `make_surface_editable`, quantized to 8 bits so a saved map reads back
    the same). The viewport Sculpt/Paint inspector gains Colour and Wetness modes (a colour picker and
    a wetness level); each stroke is one undoable step, exactly as the splat tool registers undo
    (`set_surface_region` / `get_surface_image`).
  - **Persistence.** The surface map travels through the region files: `GADSTerrainRegion` carries
    `surface_dims` + `surface_tile` (additive — absent on an old file, so a terrain that never painted
    loads unchanged), and `save_regions` / `load_regions` / `build_region_store` / the Stage 5 import
    write and reassemble it alongside height, splat and holes. A streamed world therefore carries
    colour and wetness authored on a resident terrain; painting a live sparse-streaming terrain in
    place stays DEFERRED (as Stage 4 documented — the control map is off there too), but the whole-
    resident load binds and draws it.
  - New terrain tests: `surface_paint_round_trips` (paint colour + wetness, save/load regions, the
    coalesced surface map is byte-identical, a loaded terrain rebinds it, an unpainted one binds
    nothing) and the headed `paints_colour_and_wetness` (a colour brush tints the surface red at its
    spot and nowhere else, a wetness brush darkens it, the detail field tints the spot exactly as the
    chunks do). Full suite 15/15; visual-regression baselines unchanged (no demo scene paints a
    surface).
