# Surface Displacement (Godot 4.7 addon)

UE5-style surface displacement for the Forward+ renderer: gravel that reads as individually
scattered stones, cobblestones as real stones, brick walls with deep joints.

- **Parallax occlusion mapping, done properly**, for UV, world-planar and triplanar mapping:
  adaptive steps, binary refinement, mip-correct sampling, fade to normal mapping, relief depth
  in metres, `LIGHT_VERTEX`, optional contact-hardening self-shadowing (with a `light()` that
  reproduces Godot's own shading) and opt-in depth write.
- **DisplacementField3D**: real displaced geometry for ground near the camera (LOD rings,
  crack-free, draped over your ground mesh by a top-down bake; collision unchanged), blending
  seamlessly into POM.
- **PebbleScatter3D**: loose pebbles as real meshes in camera-following GPU particle cells.
- **SurfaceDisplacement** node: Low / Medium / High / Epic presets (measured on a GTX 1080 at
  1080p: 0.47 / 1.15 / 1.58 / 2.86 ms added; near-camera geometry and pebbles only at Epic),
  feature switches, a script API for settings menus.

## Quick start

1. Enable **Surface Displacement** in Project Settings > Plugins. It registers the shader
   globals `sd_pom_steps`, `sd_pom_range`, `sd_shadow`, `sd_debug` and `sd_dfg`; keep them.
2. Add a **SurfaceDisplacement** node (Project > Tools > Surface Displacement: Add
   SurfaceDisplacement Node) and pick a preset.
3. **Convert Materials** turns StandardMaterial3D / ORMMaterial3D with a height map into SD
   materials (undoable); or use a shader from `shaders/variants/`. Set `height_m` to the real
   relief depth in metres. Height maps: 16-bit or EXR, imported **with mipmaps**.
4. Ground: select the ground mesh, **Add DisplacementField3D**, set the ground material's
   `height_center` to 0 (relief above the ground). Optionally add a PebbleScatter3D child.
5. **Validate Setup** reports what stands in the way.

Your own shaders: `render_mode diffuse_burley, specular_schlick_ggx;`, define `SD_MAPPING_UV` /
`SD_MAPPING_WORLD` / `SD_MAPPING_TRIPLANAR` and optionally `SD_POM`, `SD_SELF_SHADOW`,
`SD_DEPTH_WRITE`, then `#include "res://addons/surface_displacement/shaders/sd_surface.gdshaderinc"`
(see the files in `shaders/variants/`).

Exporting: the shader variants and the DFG table are loaded by path; export all resources, or
tick the whole `addons/surface_displacement` folder when exporting selected resources.

Requirements: Godot 4.7+, Forward+ (Vulkan tested).
Limitations: POM gives no silhouettes on walls and props; the near-camera geometry needs
height-field ground (world-planar ground materials) and its bake captures MeshInstance3D nodes
only (terrain plugins: `SDGroundBake.from_arrays()`); feet sink into the relief by
up to its depth; depth write is opt-in and costs early-Z; self-shadowing is from directional
lights only; fields follow one camera. The project README on the repository page has the
measured costs, accuracy figures, texture tools, an offline Blender bake tool, troubleshooting
and the full list.

Developed with AI assistance (Claude, Anthropic). MIT license, see LICENSE.md.
Copyright (c) 2026 M-Rocchinotti and contributors.
