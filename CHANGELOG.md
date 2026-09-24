# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.0] - unreleased (in review)

First version. Requires Godot 4.7+ with the Forward+ renderer.

### Added

- Surface shader library (`shaders/*.gdshaderinc`) and 18 generated variants: UV, world-planar
  and triplanar mapping; flat, parallax occlusion mapping (POM) and POM with self-shadowing;
  optional depth write. The march adapts its step count to the view angle and distance, bisects
  the bracketing interval and finishes with a secant step, samples one mip level computed before
  the loop, fades into plain normal mapping with the distance and over the last mip level before
  `pom_max_lod` (no edge where it ends), takes the relief depth in metres with a UE-style height
  centre, and writes `LIGHT_VERTEX`. Triplanar marches only planes with weight.
- A `light()` that reproduces Godot 4.7.2's direct lighting (Burley, Schlick-GGX, the engine's
  f90 and multiple-scattering energy compensation with a recomputed DFG table) so
  contact-hardening self-shadowing can be added without changing the look.
- Opt-in depth write with a depth rounding that keeps the depth pre-pass and the colour pass
  equal; the presets (off at Low) and the `DEPTH_WRITE` feature switch turn it off without
  losing a material's opt-in.
- `DisplacementField3D`: camera-snapped geometry clipmap with geomorphing (crack-free,
  no swimming), displaced by up to four world-planar ground layers over a top-down ground bake
  (`SDGroundBake`: 16-bit height, layer and coverage captured on the GPU and decoded in the
  shaders, slope-based step detection, `from_arrays()` for procedural terrain, at most
  4096 x 4096 texels: larger grounds get coarser texels with a warning); its fragments march the
  full-resolution relief so the grid blends into POM. The runtime bake waits until a preset shows
  the field.
- `PebbleScatter3D`: camera-following GPU-particle cells of pebbles, placed by world cell.
- `SurfaceDisplacement` node and `SDSettings`: Off / Low / Medium / High / Epic presets
  (0.47 / 1.15 / 1.58 / 2.86 ms added on a GTX 1080 at 1080p, `tools/run_benchmark.py`), feature
  switches, runtime variant switching, debug views, a script API for settings menus.
- Showcase videos (`tools/make_videos.py`): eye-level and low sweeps over the demo scenes, and
  labelled flat vs displacement comparisons.
- Editor tools: add nodes, convert materials (undoable; reports every skip reason and every
  property a conversion drops), bake the ground (undoable), prepare height maps as 16-bit EXR,
  validate the setup (including grounds too large for the bake's texel size).
- Repository tools: Poly Haven texture fetch (EXR heights, md5-checked, license records) and
  preparation, variant generator, DFG table generator, offline Blender hero bake, idle-GPU
  benchmark runner (with explore modes for the field and the parallax mip limit), screenshot
  capture, the relief range per preset and texel size (`tools/relief_range.gd`).
- Demo: gravel path, cobblestone street, rocky ground, brick wall and props, with CC0 textures,
  a flat / POM / POM + geometry comparison, presets, feature switches, debug views and a
  frame-time overlay.
- Tests: logic (also the depth-write switch's exact restore, the bake's size limit, the
  converter's reports), render (POM against a CPU ray / height-field intersection, inverted
  height remap, world-planar walls, relief drift, triplanar plane count, light() against Godot's
  lighting, LIGHT_VERTEX shadows, self-shadow against a CPU height-field shadow, depth write,
  mip shimmer, distance fade, no edge where the mip fade ends), field (vertex heights, the baked
  ground against its CPU twin, the field's own parallax and self-shadow against the CPU
  references, cracks, swimming, edge blend with and without the mip fade inside the grid, debug
  views free of lighting, bake precision, a 1 km ground, pebble stability and parameter copies,
  lifetime, no bake at Medium), demo and editor smoke, shipped archive, editor plugin actions
  with undo/redo, Blender bake; mutation checks; a log scan for engine errors and leaks.
