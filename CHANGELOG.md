# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.2.0] - unreleased

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
