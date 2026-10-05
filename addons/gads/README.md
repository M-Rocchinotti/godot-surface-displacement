# GADS - Godot Adaptive Displacement System (Godot 4.7 addon)

Adaptive surface displacement for the Forward+ renderer: gravel that reads as individually
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
- **GADSManager** node: Low / Medium / High / Ultra presets (measured on a GTX 1080 at
  1080p: 0.47 / 1.15 / 1.58 / 2.86 ms added; near-camera geometry and pebbles only at Ultra),
  feature switches, a script API for settings menus.

## Quick start

1. Enable **GADS** in Project Settings > Plugins. It registers the shader
   globals `gads_pom_steps`, `gads_pom_range`, `gads_shadow`, `gads_debug` and `gads_dfg`; keep them.
2. Add a **GADSManager** node (Project > Tools > GADS: Add
   GADSManager Node) and pick a preset.
3. **Convert Materials** turns StandardMaterial3D / ORMMaterial3D with a height map into GADS
   materials (undoable); or use a shader from `render/shaders/variants/`. Set `height_m` to the real
   relief depth in metres. Height maps: 16-bit or EXR, imported **with mipmaps**.
4. Ground: select the ground mesh, **Add GADSDisplacementField3D**, set the ground material's
   `height_center` to 0 (relief above the ground). Optionally add a GADSPebbleScatter3D child.
5. **Validate Setup** reports what stands in the way.

Your own shaders: `render_mode diffuse_burley, specular_schlick_ggx;`, define `GADS_MAPPING_UV` /
`GADS_MAPPING_WORLD` / `GADS_MAPPING_TRIPLANAR` and optionally `GADS_POM`, `GADS_SELF_SHADOW`,
`GADS_DEPTH_WRITE`, then `#include "res://addons/gads/render/shaders/gads_surface.gdshaderinc"`
(see the files in `render/shaders/variants/`).

Requirements: Godot 4.7+, Forward+ (Vulkan tested). Limitations: POM gives no silhouettes on
walls and props; the near-camera geometry needs height-field ground (world-planar ground
materials); feet sink into the relief by up to its depth; depth write is opt-in and costs
early-Z; omni and spot lights self-shadow only at High and Ultra (each one costs a march per
pixel it lights); fields follow one camera. The project README on the repository page has the
measured costs, accuracy figures, texture tools, an offline Blender bake tool, troubleshooting
and the full list.

Developed with AI assistance (Claude, Anthropic). MIT license, see LICENSE.md.
Copyright (c) 2026 M-Rocchinotti and contributors.
