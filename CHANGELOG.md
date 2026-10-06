# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.2.0] - unreleased

### Added

- **Baked displacement for any mesh: `GADSMeshInstance3D`.** The relief of a mesh's GADS
  materials made into real triangles in the editor, non-destructively: `source_mesh` is kept, the
  bake is a cached file (`res://gads_baked/<name>_<key>.mesh`) the scene refers to, reused for
  the same inputs and reported stale when the source, the materials, the settings or the
  placement change. Quality presets Draft to Ultra (tolerance relative to the relief depth,
  triangle budget) or a custom tolerance in metres; locked borders; displacement direction; hard
  edges kept; LODs; optional trimesh or convex collision from a coarser pass of its own, as an
  internal static body. Bakes run on a worker thread with progress and cancel.
- **Native adaptive tessellator** (`native/`, a GDExtension built with godot-cpp; libraries for
  Linux and Windows x86_64 in `addons/gads/native/bin/`, `tools/build_native.py` to rebuild):
  Rivara longest-edge bisection on position-welded topology (crack-free across UV seams, hard
  edges and surface borders, angles of the source kept), refinement driven by how far each
  triangle's height field deviates from it in world metres (min / max mip pyramid first), worst
  triangles first within a budget, footprint-filtered heights where the budget stopped it,
  normals rebuilt from the displaced faces, MikkTSpace tangents. Deterministic for any thread
  count.
- Shaders on a baked mesh (instance uniform `gads_baked`): no parallax march, textures mapped at
  each vertex's rest position, and only the normal-map detail finer than the triangles (the
  normal map seen from its footprint-averaged frame), so the relief is not lit twice. Debug view
  **Tessellation** (`GADSManager.DebugView.TESSELLATION`).
- **Detail displacement layer** on every GADS material (`detail_height_texture`,
  `detail_height_m`, `detail_scale`, `detail_normal_texture`, `detail_normal_strength`): a
  second, finer relief repeated `detail_scale` times per main repeat, marched, self-shadowed and
  baked together with the main one, and a detail normal map blended by Reoriented Normal
  Mapping. Off (and bit for bit unchanged) while its depth and strength are 0.
- **Layered master material** (`gads_layered_*` variants, `GADSMaterials.create_layered()`): up
  to two layers on top of the main one, each with its own textures, depth and tiling, lying
  where a vertex colour channel (or everywhere) times an amount times a slope band puts them,
  blended by height (the higher relief wins within the mask). The march, the self-shadow and
  the bake follow the blended relief; vertex colours carry into baked meshes.
- **Geometry to parallax by distance**: `GADSMeshInstance3D.geometry_range` cross-fades the
  baked geometry into the source mesh drawn with the materials' parallax beyond a distance
  (`suggest_geometry_range()` gives where the relief shrinks below two pixels), so detail goes
  geometry (with Godot's screen-space-error LODs), then parallax, then normal mapping.
- **Profiler**: the GADS bottom panel and `GADSStatsOverlay` (runtime) show per-object and total
  statistics (`GADSProfiler`): baked, source, generated and collision triangles, screen
  coverage, memory, cache size, parallax surfaces, field triangles, preset and frame costs, with
  recommendations and one-click fixes, and **Optimize for Target** (Cinematic to Mobile: preset
  and geometry ranges, settings only, undoable). `GADSHeightTools.analyse_detail()` measures the
  relief a height map carries per mip band and the size beyond which a map adds nothing.
- **Runtime deformation**: `GADSDeformationField` (a depth map over a window that follows the
  player: `stamp()`, `stroke()`, `stamp_image()`, DEEPEN / ADD / SET, rims, recovery over time
  computed in the shaders, `get_depth()` for scripts, state save and load) and
  `GADSDeformer3D` (marks from feet and wheels as they move). The field's geometry and its
  march, world-planar materials and the tops of triplanar ones are pressed down; three new
  shader globals carry it.
- **Runtime view-dependent tessellation**: `GADSMeshInstance3D.view_dependent` tessellates again
  in the background while the game runs, for the camera: each triangle's tolerance grows with its
  distance so the error stays under `pixel_error` pixels on screen (no edge split below 2 pixels,
  the worst on-screen error refined first), re-done once the camera moved `view_refresh` of its
  distance or zoomed (`view_tessellated`, `refresh_view()`). A quarter of the triangles of a
  fixed bake in the test, as fine at the eye. The tessellator takes `view_position`,
  `pixel_error`, `focal_px` and `min_edge_pixels`; its output without them is unchanged.
- **`GADSTerrain3D`**: a heightmap terrain from GADS pieces. Chunks with index LODs at every
  power of two keyed by their largest height error (so Godot's mesh LOD picks the coarsest one
  under a pixel), skirts deep enough for any pair of LODs; up to three GADS layers combined into
  one height-blended layered material (`GADSMaterials.combine_layers()`), painted by a splat map
  or by slope and height rules; HeightMapShape3D collision with the same triangulation; a
  GADSDisplacementField3D on the terrain's own ground data (texel centres on the vertices, lifted
  by what its bilinear heights can miss); `get_height()`, `get_normal()`,
  `get_layer_weights()`. `tests/terrain_tests.gd`, a demo scene (hills with a rover leaving
  tracks) and validator checks. **Streaming** (`stream_radius`): only the chunks around the camera,
  built on worker threads (identical to the whole terrain's) and freed behind it with hysteresis,
  collision per chunk, heights read from the heightmap as needed, and the detail field's ground
  data in a window that follows the camera; under 3 ms of main-thread work per frame while
  streaming a 2 km terrain. **Runtime painting** (`paint_layer()`): layers painted with a soft
  edge into the chunks' vertex colours and the field's ground data, kept for chunks streamed in
  later, savable (`get_painted_weights()`).
- Demo scene 6, **Cliff**: a curved rock face tessellated for the camera at runtime and split into
  clusters, with boulders at its foot.
- **Clustered bakes** (`GADSMeshInstance3D.cluster_triangles`): the bake split into compact
  spatial clusters (C++, median splits of the triangles' centroids), each its own instance with its
  own LODs, so large meshes are culled and LOD-selected per cluster; the same triangles as the
  unsplit bake, in the same cache file; the clusters follow the node's draw settings and switch to
  the parallax fallback together. The profiler counts them.
- **Mesh diagnostics** (`GADSMeshDiagnostics`, the inspector's **Diagnose**): the source mesh's
  open, non-manifold, UV-seam, hard and surface-border edges (drawn as coloured lines over it),
  degenerate triangles and surfaces without UVs, with what each means for the bake; Validate
  Setup warns about non-manifold edges.
- **Mobile and Compatibility renderers**: everything compiles and draws there. The field and
  pebble shaders index their layer sampler arrays with constants on Compatibility (GLSL 1.30+
  forbids a loop index there; Vulkan keeps indexing directly), and the depth write maps OpenGL's
  -1..1 clip depth to 0..1. On Compatibility a field cannot capture its ground at runtime (the
  renderer's approximate sRGB round trip breaks the height code): it stays off without a saved
  bake instead of drawing a flat sheet. `tests/renderer_tests.gd` runs on both in `run_all.py` and
  CI (CI installs Mesa's llvmpipe for OpenGL).
- **Materials from texture sets**: Project > Tools > **Create Material from Selected Textures**
  (`GADSTextureSet`): tells each file's role from its name (Substance, Quixel, Poly Haven,
  ambientCG, Blender conventions; OpenGL or DirectX normal maps), proposes texture size, relief
  depth and height remap, writes a 16-bit EXR height, a packed ORM and an OpenGL normal map where
  the set needs them, imports them and saves the GADS material.
- **Import automation**: a GADS section in the scene import options (convert height-mapped
  materials; meshes named `*-gads`, or every mesh with a GADS material, become GADSMeshInstance3D
  baked during the import, the bake stored in the imported scene). `GADSImportTools.process()`.
- Editor: Bake / Rebuild / Clear / Cancel with progress and statistics in the inspector (undoable);
  Project > Tools > **Make Selected Meshes GADSMeshInstance3D** and **Bake Selected
  GADSMeshInstance3D** (undoable); Validate Setup reports stale bakes, unbakeable meshes, a
  missing native library and bakes the budget cut short.
- **Terrain occluders**: `GADSTerrain3D.occluders` gives each chunk a conservative occluder (a
  coarse grid lowered by its own largest error, below the drawn surface everywhere) for Godot's
  occlusion culling.
- **Demo scene 7, Material lab**: procedural materials on baked spheres, a procedural tile floor
  and brick wall with cavity colours, and vector displacement curling into overhangs.
- **Platform caps and capabilities**: `GADSManager.platform_caps` (default: Low on phones and in
  browsers) caps the preset by OS feature tag or renderer while the game runs,
  `simulate_platform` tests another platform, `get_capabilities()` reports the renderer, native
  library, rendering device and cap.
- **Relief queries**: `GADSDisplacementField3D.get_surface_height()`, `get_surface_normal()` and
  `raycast_surface()` give gameplay the surface the field draws (ground plus the layers' relief
  at full resolution, minus the runtime deformation); `GADSTerrain3D.get_surface_height()` uses
  its detail field.
- **Navigation**: the field's lattice mesh no longer has CPU positions (its shader places every
  vertex), so a navigation mesh baked in a scene with a field follows the real ground instead of
  a flat lattice; terrains bake from their chunks or collision shapes (tested).
- **Custom shader hooks and visual shader nodes**: `GADS_CUSTOM_HEIGHT`
  (`gads_custom_height(uv, h)`, applied wherever the main height is read), `GADS_CUSTOM_SURFACE`
  (`gads_custom_surface(...)` after textures and effects) and `GADS_CUSTOM_LAYER_MASKS` change a
  part of the surface shader without replacing it. Visual shader nodes in a GADS category:
  ParallaxUV, HeightBlend, SlopeMask, TriplanarWeights, DetailNormal, Cavity.
- **Adaptive quality and runtime budgets**: `GADSManager.adaptive_quality` lowers the preset
  one step at a time (down to `adaptive_min_preset`) and coarsens runtime tessellation while the
  main viewport's GPU time misses `target_frame_ms`, and restores it when there is room again
  (hysteresis: a second over the target to step down, four seconds well under it to step up, a
  pause between steps); `adapt_to()` takes a game's own measurement. `runtime_triangle_budget`
  shares one budget among all view-dependent meshes by screen coverage and
  `displacement_priority`, within each one's own maximum and a minimum.
- **Surface effects and weather**: every GADS material has optional cover (snow, dust, sand on
  what faces up, tops of the relief first), wetness, puddles (flat water in the relief's low
  parts on level ground) and cavity / edge colours, limited by a vertex colour channel if wanted;
  shading only, free while off. GADSManager's Weather (`rain_wetness`, `snow_cover`,
  `puddle_level`, `set_weather()`) applies them everywhere through the `gads_weather` shader
  global, scaled by each material's `weather_response`. The near-camera field blends its layers'
  effects and the scattered pebbles follow theirs, so near and far ground match. Snow and water
  also soften the relief's normal map and self-shadow. Demo: R cycles the weather.
- The field's layer colours (albedo tint) are converted to linear like the materials' own
  `source_color` uniforms (a tinted layer drew lighter on the field than around it).
- **Sculpting baked meshes**: a Sculpt tool in the GADSMeshInstance3D inspector paints the
  surface in the 3D viewport (raise, lower, smooth, flatten; radius in metres, strength in
  millimetres; each stroke one undoable step that bakes again). The strokes are the node's
  `sculpt_map` (float, metres, in the source mesh's first UVs, saved next to the bakes), added to
  the materials' relief by the native tessellator (and refined where they change) and part of
  the bake key. `GADSSculpt` (`dab()`, `pick()`) and `get_sculpt_image()` / `sculpt_changed()` /
  `set_sculpt_image()` for scripts.
- **Export baked meshes**: `GADSMeshInstance3D.export_baked()` and an Export button in the
  inspector write the bake (every cluster) as glTF binary, glTF or OBJ with a material library,
  GADS materials as plain PBR materials; `GADSMeshExporter` for any meshes.
- **Procedural materials**: `GADSProcedural` (native `GADSHeightGenerator`) makes tileable
  height maps of eleven kinds (noise, ridged, billow, rock, stones, cracks, bricks, tiles,
  waves, ripples, craters; seed, scale, octaves, warp, gaps, bevel, variation and more) and the
  maps a material needs from any height map (normal, horizon-based ambient occlusion, curvature,
  a two-colour albedo, ORM), as images, a material in memory or a texture set on disk. Editor:
  Project > Tools > **Generate Procedural Material...** writes, imports and saves the set and
  its material. Imports by the editor tools wait for the editor's own imports and scans, so
  creating materials right after one another no longer collides with them.
- **Vector displacement in the bake**: UV-mapped materials take an optional
  `vector_displacement_texture` (XYZ offsets per texel, tangent or object space, signed or
  0..1 around 0.5) times `vector_displacement_m`. A `GADSMeshInstance3D` bake moves its vertices
  by it, on top of or instead of the height map, refines where the offset changes (sideways
  relief as well as height) and keeps seams closed. Validate Setup reports a vector map on a node
  that does not bake and a signed map stored in 8 bits.
- `GADSDeformationField.stroke()` ruts have softer walls than round marks; a field that follows a
  node not yet in the tree (a later sibling) centres on itself until it is.
- `tests/bake_tests.gd` (132 checks) and editor-check steps for the new tools; CI builds the
  native library from source for Linux and Windows and runs the headless suites on Windows.

### Changed

- **Renamed to GADS (Godot Adaptive Displacement System).** The addon now lives in
  `addons/gads/`, laid out by subsystem (`core/`, `materials/`, `render/shaders/`, `terrain/`,
  `editor/`, `import/`). Scenes and scripts need these renames:

  | 0.1 | 0.2 |
  |---|---|
  | `addons/surface_displacement/` | `addons/gads/` |
  | `SurfaceDisplacement` (node) | `GADSManager` |
  | `SDSettings`, `SDMaterials`, `SDGlobals` | `GADSSettings`, `GADSMaterials`, `GADSGlobals` |
  | `SDGroundBake`, `SDHeightTools` | `GADSGroundBake`, `GADSHeightTools` |
  | `SDMaterialConverter`, `SDValidator` | `GADSMaterialConverter`, `GADSValidator` |
  | `DisplacementField3D`, `PebbleScatter3D` | `GADSDisplacementField3D`, `GADSPebbleScatter3D` |
  | shader globals `sd_pom_steps`, `sd_pom_range`, `sd_shadow`, `sd_debug`, `sd_dfg` | `gads_pom_steps`, `gads_pom_range`, `gads_shadow`, `gads_debug`, `gads_dfg` |
  | shaders `shaders/variants/sd_<mapping>_<quality>[_depth].gdshader` | `render/shaders/variants/gads_<mapping>_<quality>[_depth].gdshader` |
  | shader library `sd_*.gdshaderinc`, `SD_*` defines | `gads_*.gdshaderinc`, `GADS_*` defines |
  | preset `Epic` | `Ultra` (same settings) |
  | ground group `sd_ground`, texture metadata `<id>.sd.json` | `gads_ground`, `<id>.gads.json` |
  | `SDMaterials.is_sd_material()` | `GADSMaterials.is_gads_material()` |
  | height conversion output `<name>_sd_height.exr` | `<name>_gads_height.exr` |

  Material parameters (`height_m`, `albedo_texture`, ...) keep their names. After updating,
  enable the plugin once so it registers the `gads_*` shader globals (the `sd_*` entries in
  Project Settings > Shader Globals can then be removed).

## [0.1.0] - unreleased (in review)

First version. Requires Godot 4.7+ with the Forward+ renderer.

### Added

- Surface shader library (`shaders/*.gdshaderinc`) and 18 generated variants: UV, world-planar
  and triplanar mapping; flat, parallax occlusion mapping (POM) and POM with self-shadowing;
  optional depth write. The march adapts its step count to the view angle and distance, bisects
  the bracketing interval and finishes with a secant step, samples one mip level computed before
  the loop, fades into plain normal mapping, takes the relief depth in metres with a
  UE-style height centre, and writes `LIGHT_VERTEX`. Triplanar marches only planes with weight.
- A `light()` that reproduces Godot 4.7.2's direct lighting (Burley, Schlick-GGX, the engine's
  f90 and multiple-scattering energy compensation with a recomputed DFG table) so
  contact-hardening self-shadowing can be added without changing the look.
- Opt-in depth write with a depth rounding that keeps the depth pre-pass and the colour pass
  equal.
- `DisplacementField3D`: camera-snapped geometry clipmap with geomorphing (crack-free,
  no swimming), displaced by up to four world-planar ground layers over a top-down ground bake
  (`SDGroundBake`: 16-bit height, layer and coverage captured on the GPU and decoded in the
  shaders, slope-based step detection, `from_arrays()` for procedural terrain); its fragments
  march the full-resolution relief so the grid blends into POM.
- `PebbleScatter3D`: camera-following GPU-particle cells of pebbles, placed by world cell.
- `SurfaceDisplacement` node and `SDSettings`: Off / Low / Medium / High / Epic presets
  (0.47 / 1.15 / 1.58 / 2.86 ms added on a GTX 1080 at 1080p, `tools/run_benchmark.py`), feature
  switches, runtime variant switching, debug views, a script API for settings menus. Presets
  reach SD materials wherever a scene draws them: mesh surfaces, overrides, overlays and
  `next_pass` chains, MultiMeshes, particles, CSG shapes and GridMap mesh libraries
  (`SDMaterials.materials_of()`). Edits to a Custom preset's `SDSettings` apply live.
- Self-shadowing from omni and spot lights (`SDSettings.self_shadow_local_lights`, on at High
  and Epic), in the surface and the field shaders; checked against a CPU height-field shadow
  towards the light's position.
- Showcase videos (`tools/make_videos.py`): eye-level and low sweeps over the demo scenes, and
  labelled flat vs displacement comparisons.
- Editor tools: add nodes, convert materials on meshes and CSG shapes (undoable), bake the ground
  (undoable), prepare height maps as 16-bit EXR, validate the setup (including UV-mapped
  materials on meshes without UVs, ground materials a field leaves flat, a bake made
  for other layers, a pebble scatter outside a field, a Custom preset without settings).
- Repository tools: Poly Haven texture fetch (EXR heights, md5-checked, license records) and
  preparation, variant generator, DFG table generator, offline Blender hero bake, idle-GPU
  benchmark runner, screenshot capture.
- Demo: gravel path, cobblestone street, rocky ground, brick wall and props, with CC0 textures,
  a flat / POM / POM + geometry comparison, presets, feature switches, debug views and a
  frame-time overlay.
- Tests: logic, render (POM against a CPU ray / height-field intersection, inverted height
  remap, world-planar walls, relief drift, triplanar plane count, light() against Godot's
  lighting, LIGHT_VERTEX shadows, self-shadow against a CPU height-field shadow, depth write,
  mip shimmer, distance fade), field (vertex heights, the baked ground against its CPU twin, the
  field's own parallax and self-shadow against the CPU references, cracks, swimming, edge blend,
  bake precision, pebble stability, lifetime), demo and editor smoke, shipped archive, editor
  plugin actions with undo/redo, Blender bake; mutation checks; a log scan for engine errors and
  leaks. They also pass on Linux with Mesa's lavapipe software Vulkan, which a GitHub Actions
  workflow (`.github/workflows/tests.yml`) runs on every push.

### Fixed (since the review build)

- The demo's fly camera never moved: its script was attached after the camera was ready, so
  Godot never turned on its processing.
- `PebbleScatter3D` set the field's texture parameters on its materials every frame, which made
  the renderer rebuild two uniform sets per frame; it now copies them when the field changes
  them.
- A ground-group `MeshInstance3D` without a mesh stretched the ground bake to its origin.
- Two checks failed on drivers that round towards zero when writing half floats or bleed a trace
  of geometry into the background next to a silhouette (Mesa's lavapipe): the baked ground's
  vertex heights are now read back around 0 m (0.1 mm half-float steps instead of 0.2 mm), and
  "self-shadow strength 0" checks the traced relief pixels (which also catches a wrongly black
  pixel) instead of every non-black one. The log scan ignores errors located in an audio driver
  (ALSA on a machine without a sound card), like the WASAPI ones. The mip shimmer test also
  compares the march's mip level with the hardware's directly: on lavapipe, a march at mip 0 did
  not flicker enough to fail the flicker limit.
