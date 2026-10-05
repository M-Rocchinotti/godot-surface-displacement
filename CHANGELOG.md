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
  the loop, fades into plain normal mapping, takes the relief depth in metres with a
  UE-style height centre, and writes `LIGHT_VERTEX`. Triplanar marches only planes with weight.
- Emission (`emission_texture` x `emission_color` x `emission_energy`) sampled at the relief
  hit, so emissive relief (lava between rocks, glowing cracks) stays in place under parallax;
  DisplacementField3D layers carry it, and the debug views replace it.
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
  switches, runtime variant switching, debug views, a script API for settings menus.
- Showcase videos (`tools/make_videos.py`): eye-level and low sweeps over the demo scenes, and
  labelled flat vs displacement comparisons.
- Editor tools: add nodes, convert materials (undoable; emission carries over, Add and Multiply
  operators and physical light units included), bake the ground (undoable), prepare height maps
  as 16-bit EXR, validate the setup.
- Repository tools: Poly Haven texture fetch (EXR heights, md5-checked, license records) and
  preparation, variant generator, DFG table generator, offline Blender hero bake, idle-GPU
  benchmark runner, screenshot capture.
- Demo: gravel path, cobblestone street, rocky ground, brick wall and props, with CC0 textures,
  a flat / POM / POM + geometry comparison, presets, feature switches, debug views and a
  frame-time overlay.
- Tests: logic (including the material converter), render (POM against a CPU ray / height-field
  intersection, emission read at the traced hit, converted emission against StandardMaterial3D,
  inverted height remap, world-planar walls, relief drift, triplanar plane count, light()
  against Godot's lighting, LIGHT_VERTEX shadows, self-shadow against a CPU height-field shadow,
  depth write, mip shimmer, distance fade), field (vertex heights, the baked ground against its
  CPU twin, the field's own parallax, self-shadow and layer emission against the CPU references,
  cracks, swimming, edge blend, bake precision, pebble stability, lifetime), demo and editor
  smoke, shipped archive, editor plugin actions with undo/redo, Blender bake; mutation checks; a
  log scan for engine errors and leaks.
