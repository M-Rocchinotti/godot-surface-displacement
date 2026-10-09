# GADS - Godot Adaptive Displacement System (Godot 4.7 addon)

Adaptive surface displacement for Godot's Forward+, Mobile and Compatibility renderers: gravel that reads as individually
scattered stones, cobblestones as real stones, brick walls with deep joints.

- **Parallax occlusion mapping, done properly**, for UV, world-planar and triplanar mapping:
  adaptive steps, binary refinement, mip-correct sampling, fade to normal mapping, relief depth
  in metres, `LIGHT_VERTEX`, optional contact-hardening self-shadowing from the sun and from
  omni and spot lights (with a `light()` that reproduces Godot's own shading) and opt-in depth
  write.
- **GADSDisplacementField3D**: real displaced geometry for ground near the camera (LOD rings,
  crack-free, draped over your ground mesh by a top-down bake; collision unchanged), blending
  seamlessly into POM.
- **GADSPebbleScatter3D**: loose pebbles as real meshes in camera-following GPU particle cells.
- **GADSMeshInstance3D**: the relief of any mesh baked into real triangles in the editor by a
  native adaptive tessellator (dense only where the height map needs it, crack-free across seams
  and hard edges, rebuilt normals and tangents, LODs, optional collision). Non-destructive and
  cached; Bake / Rebuild / Clear in the inspector; bakes can stream in near the camera
  (`stream_bake`); paint the layered materials' layers on any mesh (vertex colours, on a copy of
  the mesh); a selected baked mesh bakes again by itself when its material changes (Live). The
  native library ships for Linux x86_64 and ARM64, Windows x86_64, Android and Web (`native/`);
  on macOS and iOS a slower GDScript tessellator bakes.
- **GADSDeformationField** / **GADSDeformer3D**: footprints, tracks and craters written at runtime,
  pressing the field's geometry and the ground's parallax down; persistent, recovering.
- **GADSTerrain3D**: a heightmap terrain with chunk LODs by screen-space error, up to three
  height-blended GADS layers (splat map or slope / height rules), HeightMapShape3D collision and
  the near-camera displacement field on its own ground data; sculpt and paint it in the viewport
  (undoable) or from scripts at runtime; roads along curves (GADSTerrainPath3D); generate
  landscapes, erode them (hydraulic and thermal erosion), cut holes (cave and tunnel
  entrances) and export the heights as EXR. **GADSReliefCollider3D** puts characters' feet on
  the relief instead of the smooth ground collision.
- **GADSManager** node: Low / Medium / High / Ultra presets (measured on a GTX 1080 at
  1080p: 0.47 / 1.15 / 1.58 / 2.86 ms added; near-camera geometry and pebbles only at Ultra),
  feature switches, adaptive quality against a frame-time target, a shared runtime triangle
  budget, weather (rain, snow, puddles); `GADS.set_quality()` for a game's settings menu and
  `GADS.surface(node)` for one node's relief in metres.
- **Materials**: detail layers, height-blended layered materials, surface effects (snow / dust /
  sand cover, wetness, puddles, cavity and edge colours), vector displacement maps for bakes,
  per-node depth and tint; twelve **surface presets** (Brick, Rock, Cliff, Snow, Metal Damage...)
  that set how the relief is drawn; materials from downloaded texture sets (the surface detected
  from the name) or **procedural** ones (thirteen tileable patterns with normal, occlusion,
  albedo and ORM maps). The **GADS Height Map** importer reads 16-bit PNGs and RAW / R16
  heightmaps at full precision, with Max / Min mip filters.
- **Import profiles**: name meshes `Rock-gads-rock`, `Wall-gads-wall` (rock, wall, terrain, prop,
  character) or pick a profile in the scene import options.
- **Baked meshes** (GADSMeshInstance3D) also re-tessellate for the camera at runtime, split into
  clusters for culling and LOD, show their topology problems (Diagnose), can be **sculpted** by
  hand in the viewport (raise, lower, smooth, flatten; undoable, baked again per stroke) and
  export to glTF / OBJ.
- **Custom shaders**: the `.gdshaderinc` library with hooks (height, surface, layer masks) and
  six visual shader nodes in a GADS category.

## Quick start

1. Enable **GADS** in Project Settings > Plugins. It registers the shader
   globals `gads_pom_steps`, `gads_pom_range`, `gads_pom_fade_px`, `gads_shadow`, `gads_debug`,
   `gads_dfg`, the three `gads_deform*` of runtime deformation and `gads_weather`; keep them.
2. Add a **GADSManager** node (Project > Tools > GADS: Add
   GADSManager Node) and pick a preset.
3. **Create Material from Selected Textures** makes a GADS material from a downloaded texture set
   selected in the FileSystem dock; **Convert Materials** turns StandardMaterial3D /
   ORMMaterial3D with a height map into GADS materials (undoable); or use a shader from
   `render/shaders/variants/`. Set `height_m` to the real
   relief depth in metres. Height maps: 16-bit or EXR, imported **with mipmaps**.
4. Ground: select the ground mesh, **Add GADSDisplacementField3D**, set the ground material's
   `height_center` to 0 (relief above the ground). Optionally add a GADSPebbleScatter3D child.
5. Props whose outline should follow the relief: **Make Selected Meshes GADSMeshInstance3D**,
   then **Bake** in the inspector; or name them `*-gads` in your modelling tool and they arrive
   baked (scene import options, GADS section).
6. **Validate Setup** reports what stands in the way.

Your own shaders: `render_mode diffuse_burley, specular_schlick_ggx;`, define `GADS_MAPPING_UV` /
`GADS_MAPPING_WORLD` / `GADS_MAPPING_TRIPLANAR` and optionally `GADS_POM`, `GADS_SELF_SHADOW`,
`GADS_DEPTH_WRITE`, then `#include "res://addons/gads/render/shaders/gads_surface.gdshaderinc"`
(see the files in `render/shaders/variants/`). Hooks: define `GADS_CUSTOM_HEIGHT` with
`float gads_custom_height(vec2 uv, float h)` before the include, or `GADS_CUSTOM_SURFACE` with
`gads_custom_surface(...)` between `gads_core.gdshaderinc` and `gads_surface.gdshaderinc` (the
header of `gads_core.gdshaderinc` lists the signatures).

Requirements: Godot 4.7+, Forward+ (Vulkan tested). Limitations: POM gives no silhouettes on
walls and props (bake those); without the native library (shipped for Linux x86_64 and ARM64,
Windows x86_64, Android and Web; not macOS or iOS)
bakes are slower and without vector displacement or runtime tessellation;
skinned and morphing meshes bake in their rest pose; the near-camera geometry needs height-field
ground (world-planar ground materials); feet sink into the relief unless a GADSReliefCollider3D
follows them; depth write is opt-in and costs
early-Z; omni and spot lights self-shadow only at High and Ultra (each one costs a march per
pixel it lights); fields follow one camera. The project README on the repository page has the
measured costs, accuracy figures, texture tools, an offline Blender bake tool, troubleshooting
and the full list.

Developed with AI assistance (Claude, Anthropic). MIT license, see LICENSE.md.
Copyright (c) 2026 M-Rocchinotti and contributors.
