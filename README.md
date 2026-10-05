# GADS - Godot Adaptive Displacement System

Adaptive surface displacement for Godot 4.7's Forward+ renderer: gravel that reads as
individually scattered stones, cobblestones as real stones, brick walls with deep joints - from
ordinary PBR texture sets with a height map. The goal is to make true geometric displacement in
Godot as easy as applying a normal map. GADS grew out of the Surface Displacement addon (0.1);
the rename is the only change scenes and scripts need, see [CHANGELOG.md](CHANGELOG.md).

![Gravel path at eye level: flat normal mapping, POM, POM + geometry](docs/images/gravel_path_eye_level_compare.jpg)
![Gravel path at a grazing angle: flat normal mapping, POM, POM + geometry](docs/images/gravel_path_grazing_compare.jpg)

*Gravel path (Poly Haven clean_pebbles), at eye level and at a grazing angle. Left to right: flat
(normal mapping only, preset Off), POM (Ultra parallax and self-shadowing), POM + geometry (Ultra
with the near-camera geometry and pebble scatter). Captured by `tools/capture_screenshots.gd`.*

| | |
|---|---|
| ![Cobblestone street](docs/images/cobblestone_street_eye_level_compare.jpg) | ![Rocky ground](docs/images/rocky_ground_eye_level_compare.jpg) |
| Cobblestone street, eye level (flat / POM / POM + geometry) | Rocky ground, eye level |
| ![Cobblestone street, grazing](docs/images/cobblestone_street_grazing_compare.jpg) | ![Brick wall and props](docs/images/brick_wall_eye_level_compare.jpg) |
| Cobblestone street, grazing | Brick wall and props, eye level |

Full-size single images of every scene, view and mode are in [docs/images](docs/images)
(`<scene>_<view>_<flat|pom|pom_geometry>.jpg`), all from `tools/capture_screenshots.gd`.

Godot 4.7 has no tessellation and no Nanite, so the addon combines three layers that each do
what the engine allows:

1. **Parallax occlusion mapping (POM), done properly**, on any mesh: adaptive step count,
   binary refinement, mip-correct sampling, a fade into plain normal mapping, relief depth in
   metres, lighting and received shadows at the relief (`LIGHT_VERTEX`), optional
   contact-hardening self-shadowing with a `light()` that reproduces Godot's own shading, and
   opt-in depth write so props sink into the relief. UV, world-planar and triplanar mapping.
2. **Real displaced geometry near the camera** for ground (`GADSDisplacementField3D`): a
   camera-centred grid of LOD rings (15.4 m across at Ultra), crack-free, displaced by the same height
   maps, draped over any ground mesh via a top-down bake. Stones get silhouettes and real
   depth; the ground's collision is unchanged. It blends seamlessly into POM beyond the grid.
3. **Pebble scatter** (`GADSPebbleScatter3D`): loose pebbles as real little meshes in camera-following
   GPU particle cells.
4. **Baked displacement for any mesh** (`GADSMeshInstance3D`): the relief made into real
   triangles in the editor by a native adaptive tessellator - dense only where the height map
   needs it, crack-free across UV seams and hard edges, with rebuilt normals and tangents, LODs
   and an optional collision shape. Non-destructive and cached: the source mesh stays, the bake is
   a file the scene refers to, Bake / Rebuild / Clear in the inspector. For props, rocks and
   walls whose silhouette, shadows or collision POM cannot give.

## Features

- Ready-made shaders for UV, world-planar and triplanar mapping, each flat / POM /
  POM + self-shadow, the POM ones optionally with depth write, single or layered (30 surface
  shaders plus 3 for the field, generated from one `.gdshaderinc` library you can include in
  your own shaders).
- Multiple displacement layers: a detail relief and detail normal map on every material, and
  layered materials with up to three height-blended layers masked by vertex colour and slope.
- POM measured against a CPU ray / height-field intersection: 0.13 mm 90th-percentile hit error
  on a 50 mm relief, from steep to grazing views, for all mappings (`tests/render_tests.gd`).
- Self-shadowing whose `light()` matches Godot's built-in lighting to 0.07 % (99th percentile),
  from the sun and (High and Ultra) from omni and spot lights.
- Triplanar that marches only the planes with weight (1 plane on a floor, 2 on a 45-degree roof).
- Near-camera geometry with geomorphing between rings: zero cracks, no swimming, heights exact
  to 0.03 mm against the height map.
- Presets Low / Medium / High / Ultra, measured on a GTX 1080 at 1080p at 0.47 / 1.15 / 1.58 /
  2.86 ms added (budgets 0.5 / 1.2 / 2.0 / 3.0 ms), plus per-feature switches and a small script
  API for settings menus.
- Baked adaptive displacement: Rivara longest-edge bisection on welded topology driven by the
  height field's own deviation (in metres), a triangle budget, MikkTSpace tangents, LODs, collision at its own resolution; on a baked mesh the same materials
  skip their march and add only the normal-map detail finer than the triangles.
- Editor tools: add nodes, convert StandardMaterial3D / ORMMaterial3D with a height map (undoable),
  make meshes GADSMeshInstance3D and bake them (undoable, with progress and cancel), bake the
  ground under a field, turn 8-bit height maps into 16-bit EXR, validate the setup.
- A demo with four scenes (gravel path, cobblestone street, rocky ground, brick wall and
  props), a flat / POM / POM + geometry comparison and a frame-time overlay.

## Requirements

- **Godot 4.7** or newer (developed and tested on 4.7.2-stable).
- The **Forward+** renderer (Vulkan tested on Windows 10, NVIDIA GeForce GTX 1080; every test
  suite also passes on Linux with Mesa's lavapipe software Vulkan, as in CI). Mobile and
  Compatibility are untested; the near-camera geometry and scatter need a rendering device.
- Height maps with more than 8 bits (16-bit PNG or EXR). 8-bit height maps work but terrace
  visibly once displaced by more than a few centimetres.
- Baked displacement (`GADSMeshInstance3D`) needs the GADS native library, which ships for
  **Linux and Windows x86_64** (`addons/gads/native/`). Elsewhere everything else works and baked
  meshes made on a supported platform still draw; to bake there, build the library from
  `native/` (see [Building the native library](#building-the-native-library)).
- Optional: Python 3.10+ with numpy and Pillow for the texture tools, Blender 4.5 LTS for the
  offline hero bake.

## Installation

1. **Asset Store / Asset Library:** search for "GADS" and install it.
   **By hand:** copy `addons/gads` into your project's `addons/` folder. It is
   self-contained.
2. Enable **GADS** in Project > Project Settings > Plugins. It registers five
   global shader uniforms (`gads_pom_steps`, `gads_pom_range`, `gads_shadow`, `gads_debug`, `gads_dfg`) in
   Project Settings > Shader Globals. Keep them: every GADS shader reads them.
3. If materials failed to compile before the plugin was enabled, reload the project once.

## Quick start

1. Add a **GADSManager** node to your scene (Project > Tools > GADS: Add
   GADSManager Node). Pick a preset.
2. Give your surfaces GADS materials:
   - **Convert Materials** turns every StandardMaterial3D / ORMMaterial3D with a height map in
     the selection (or scene), on meshes and CSG shapes, into the matching UV or triplanar GADS
     material (undoable). Then
     set each material's `height_m` to the real depth of its relief.
   - Or create one in the inspector: a ShaderMaterial with a shader from
     `addons/gads/render/shaders/variants/` (`gads_<uv|world|triplanar>_<flat|pom|pom_ss>[_depth].gdshader`).
   - Or in code:

     ```gdscript
     var gravel := GADSMaterials.create(GADSMaterials.Mapping.WORLD,
         {"albedo": load("res://gravel_albedo.jpg"), "normal": load("res://gravel_normal.jpg"),
          "orm": load("res://gravel_arm.jpg"), "height": load("res://gravel_height.exr")},
         {"height_m": 0.03, "texture_size_m": Vector2(2, 2)})
     ```
3. For ground you walk on: select the ground mesh and run **Add GADSDisplacementField3D**. The field
   takes the ground's material as its layer, puts the ground into the `gads_ground` group, and
   bakes it at runtime (or run **Bake Ground** once in the editor to save `<scene>_ground.res`;
   baking again overwrites that file, so undo cannot bring an earlier bake back).
   Set the ground material's `height_center` to 0 (relief above the ground; see below).
   Add a **GADSPebbleScatter3D** as the field's child for loose pebbles.
4. For a prop whose outline, shadows or collision should follow the relief (a rock, a wall end, a
   statue), select it and run **Make Selected Meshes GADSMeshInstance3D**, then press **Bake** in
   the inspector (see [GADSMeshInstance3D](#gadsmeshinstance3d-baked-displacement)).
5. Run **Validate Setup** if something looks wrong; it lists missing globals, wrong texture
   imports, UV-mapped materials on meshes without UVs, materials the field cannot
   use, ground materials the field leaves flat, a bake made for other layers, a pebble scatter
   outside a field and more.

## Configuration

### Materials

| Parameter | Default | Meaning |
|---|---|---|
| `albedo_texture`, `albedo_tint` | white | Base colour. |
| `normal_texture`, `normal_strength` | flat, 1 | OpenGL-convention normal map (+Y up, as Godot). |
| `orm_texture` | white | R = ambient occlusion, G = roughness, B = metallic (Poly Haven "arm"). |
| `ao_strength`, `roughness_scale`, `metallic_scale`, `specular` | 1, 1, 0, 0.5 | As in ORMMaterial3D. |
| `height_texture` | white | Height in the red channel, 1 = top. **Import with mipmaps** (the march samples the right mip level; without mipmaps it aliases and costs more). Lossless or half-float. |
| `height_m` | 0.03 | Relief depth in **metres** from the lowest to the highest point. |
| `height_center` | 1 | Height that stays on the surface (UE's Displacement Center): 1 = relief carved into the surface (walls, props), 0 = relief standing on it (ground under a GADSDisplacementField3D). |
| `height_remap` | (0, 1) | Height values mapped to 0 and 1. |
| `pom_steps_scale` | 1 | Per-material multiplier on the preset's step counts. |
| `self_shadow_strength` | 1 | 0 = no self-shadow on this material. |
| `uv_scale`, `uv_offset` | 1, 0 | UV mapping. |
| `texture_size_m`, `planar_offset_m` | 2 m, 0 | World and triplanar mapping: the size of one texture repeat and the texture's origin, in metres. |
| `planar_rotation_deg` | 0 | World mapping: the texture's turn about the vertical axis. |
| `triplanar_sharpness` | 4 | Blend sharpness; planes under 5 % weight are dropped. |
| `detail_height_texture`, `detail_height_m` | black, 0 | Optional detail relief on top of the main one (grain on stones, chips in bricks): `detail_height_m * (d - 0.5)`, marched, self-shadowed and baked together with the main relief. Off at 0. |
| `detail_normal_texture`, `detail_normal_strength` | flat, 0 | Optional detail normal map, blended onto the main one (Reoriented Normal Mapping). Off at 0. |
| `detail_scale` | 8 | Detail repeats per main texture repeat. |

#### Layered materials

`gads_layered_<mapping>_<quality>[_depth].gdshader` (or `GADSMaterials.create_layered()`) puts up
to two more layers on top of the main one, each with its own albedo, normal, ORM and height
maps, depth (`layerN_height_m`) and tiling (`layerN_scale`, repeats per main repeat). A layer
lies where its mask is: a vertex colour channel or everywhere (`layerN_mask_channel`), times
`layerN_amount`, times a band of the surface's up-facing when `layerN_slope.y > layerN_slope.x`
(`(0.6, 0.85)`: tops only, for moss or snow). Within the mask the higher relief wins
(height-aware blending: sand fills the gaps between stones before it covers them), with a
transition `layerN_blend_width` high. The march, the self-shadow and the bake all follow the
blended relief; GADSManager presets switch layered materials like any other.

```gdscript
var ground := GADSMaterials.create_layered(GADSMaterials.Mapping.WORLD,
    {"albedo": rocks_albedo, "normal": rocks_normal, "orm": rocks_arm, "height": rocks_height},
    {"height_m": 0.06, "height_center": 0.0},
    [{"albedo": sand_albedo, "normal": sand_normal, "height": sand_height, "height_m": 0.02,
      "mask": GADSMaterials.LayerMask.VERTEX_R},                  # painted with vertex colour R
     {"albedo": snow_albedo, "height": snow_height, "height_m": 0.03,
      "mask": GADSMaterials.LayerMask.EVERYWHERE, "slope": Vector2(0.6, 0.85)}])  # on tops
```

Your own shaders can use the library the same way the variants do: `render_mode
diffuse_burley, specular_schlick_ggx;` (the `light()` reproduces these modes), `#define
GADS_MAPPING_UV` (or `GADS_MAPPING_WORLD`, `GADS_MAPPING_TRIPLANAR`), optionally `GADS_POM`,
`GADS_SELF_SHADOW`, `GADS_DEPTH_WRITE`, then `#include
"res://addons/gads/render/shaders/gads_surface.gdshaderinc"`.

Depth write is a separate shader variant (`..._depth.gdshader`, or
`GADSMaterials.set_depth_write(material, true)`): props then intersect the relief instead of the
flat surface. It costs early-Z for the material and runs the POM march in the depth pre-pass
too; use it on the few surfaces where objects stand close to deep relief (a wall with a crate
against it). See [Limitations](#limitations).

### The GADSManager node

| Property | Default | Meaning |
|---|---|---|
| `enabled` | on | Off = the Off preset. |
| `preset` | Medium | Off / Low / Medium / High / Ultra / Custom (`custom_settings`, an `GADSSettings`; changing its values applies them). |
| `pom`, `self_shadow`, `near_field`, `scatter` | on | Feature switches. They can only take a feature away from the preset, never add one. |
| `debug_view` | Off | Hit offset, march cost, relief height, normals, self-shadow, field rings. |

One node per project scene; it writes the shader globals, switches every registered material
between its flat / POM / POM + self-shadow variant at runtime, and configures the fields and
scatters. Materials in the scene are registered automatically, also those added later: on
meshes (surface materials, overrides and overlays, and their `next_pass` chains), MultiMeshes,
particles, CSG shapes and GridMap mesh libraries. `register_material()` / `register_scene()`
cover materials created in code but not yet in the tree, or assigned to a node already in it.
In the editor the node only writes the globals, so saved materials keep their variant.

Script API for a settings menu:

```gdscript
var gads := GADSManager.find_in(get_tree())
gads.preset = GADSSettings.Preset.HIGH
gads.set_feature(GADSManager.Feature.SCATTER, false)
gads.is_feature_active(GADSManager.Feature.NEAR_FIELD)   # preset AND switch
gads.get_budget_ms()                                             # target cost of the preset
gads.settings_changed.connect(_refresh_menu)
```

### Presets and measured cost

| Preset | POM steps (min-max, bisection) | Relief fades out | Self-shadow | Near-camera geometry | Pebbles |
|---|---|---|---|---|---|
| Off | - (normal mapping) | - | - | - | - |
| Low | 4-10, secant only | 8-14 m | - | - | - |
| Medium | 8-20, 3 | 18-30 m | hard, 6 steps, to 15 m; sun | - | - |
| High | 10-28, 4 | 25-40 m | soft, 12 steps, to 25 m; sun, omni, spot | - | - |
| Ultra | 8-20, 3 | 20-35 m | soft, 8 steps, to 20 m; sun, omni, spot | 3 rings x 96 at 4 cm (to 7.7 m) | to 8 m |

(`core/gads_settings.gd`; Custom takes an `GADSSettings` resource with every value.) Ultra has
slightly fewer parallax steps and a shorter fade than High: the near-camera geometry's fragments
march the relief too (twice, see [ARCHITECTURE.md](docs/ARCHITECTURE.md#45-what-the-field-costs-and-why)),
and the budget goes there.

Measured with `python tools/run_benchmark.py --allow-idle-unreal` (it runs `tests/benchmark.gd`
once the GPU has been idle for 3 minutes and no other rendering engine runs; an open, idle Unreal
editor was tolerated and the run was checked for engines starting during it). NVIDIA GeForce GTX
1080, Vulkan 1.4.312, Godot 4.7.2, 1920 x 1080, V-Sync off. Scene: open ground of the demo's
gravel (Poly Haven clean_pebbles) under a shadowed sun with SSAO, seen from eye level so the
ground covers about 60 % of the frame, the camera panning along a fixed path. Each row: median of
3 runs of 300 frames after 150 warm-up frames; "added" is the viewport GPU time minus the same
ground with an ORMMaterial3D (same textures and texel density, normal mapping only; 1.408 ms,
measured before and after the rows). Full output: [docs/benchmark_results.md](docs/benchmark_results.md).

| Preset | Added GPU time | Target | Spread of the 3 runs |
|---|---|---|---|
| Off | 0.09 ms | - | 0.010 ms |
| Low | **0.47 ms** | 0.5 ms | 0.003 ms |
| Medium | **1.15 ms** | 1.2 ms | 0.025 ms |
| High | **1.58 ms** | 2.0 ms | 0.004 ms |
| Ultra | **2.86 ms** | 3.0 ms | 0.014 ms |

What the features cost (same run): Ultra without pebbles 2.84 ms (the pebbles cost about
0.02 ms), without the near-camera geometry 1.24 ms (so the geometry costs 1.6 ms), and without
geometry and self-shadowing 0.90 ms. Opt-in depth write on the Medium ground: 1.52 ms (+0.37 ms).
Off costs 0.09 ms more than ORMMaterial3D (the flat variant's own normal-map frame). The costs
scale with the screen area the relief covers; walls and props at a distance cost little, and
everything beyond the fade distance is plain normal mapping.

### GADSDisplacementField3D

| Property | Default | Meaning |
|---|---|---|
| `layers` | - | Up to four GADS ground materials (world-planar mapping, `height_center` 0). The field copies their textures and parameters (`sync_layers()` after changing them in code). |
| `ground_bake` | - | An `GADSGroundBake`. Without one the field bakes at runtime (`bake_on_ready`), or displaces a flat plane at its own height. |
| `ground_group`, `bake_texel_size` | `gads_ground`, 5 cm | What is baked, and how finely. |
| `levels`, `resolution`, `base_spacing` | 3, 96, 4 cm | Rings, quads per ring side, finest vertex spacing (the defaults are Ultra's: the geometry reaches 7.7 m from the camera). Denser grids cost much more than they show, see [Presets and measured cost](#presets-and-measured-cost). |
| `lift`, `fade_band` | 2 mm, 0.25 | Height above the ground mesh; outer fraction of the grid where the relief fades to flat. |
| `cast_shadows` | off | Shadows of the displaced geometry (the POM self-shadow already shadows the relief). |
| `camera` | active | The camera the grid follows. |

The field is drawn on top of the original ground and replaces its look where a layer is
displaceable. Collision stays on the original ground.

### GADSPebbleScatter3D

A child of a GADSDisplacementField3D. `density`, `radius` (8 m), `per_cell` (24), `cell_size` (1 m),
`size_range` (1.2-3.5 cm), `valley_bias` (preference for low points of the height map) and
`layer_density` (per field layer, default only layer 0).

### GADSMeshInstance3D (baked displacement)

A MeshInstance3D whose GADS materials' relief is baked into real geometry. Make one from a
selected mesh (**Project > Tools > GADS: Make Selected Meshes GADSMeshInstance3D**, undoable: the
mesh becomes `source_mesh`) or add the node and set `source_mesh`. The inspector shows **Bake**
(reuses a cached bake of the same inputs), **Rebuild** (ignores the cache), **Clear** (back to
the source mesh), **Cancel**, a progress bar and the bake's statistics; bakes run on a worker
thread and are undoable. **Bake Selected GADSMeshInstance3D** in Project > Tools bakes several.

| Property | Default | Meaning |
|---|---|---|
| `source_mesh` | - | The mesh to displace; never modified. Any triangle mesh, any number of surfaces (each displaced by its own GADS material; surfaces without one are kept and refined only along shared edges). |
| `quality` | Medium | Draft / Low / Medium / High / Ultra: tolerance 5 / 2.5 / 1.25 / 0.6 / 0.3 % of the deepest relief (`height_m`), budget 25 k / 75 k / 200 k / 500 k / 1.5 M triangles. Custom: `custom_max_error` (m) and `custom_max_triangles`. |
| `min_edge_texels` | 1 | No edge is split below this many height-map texels. |
| `lock_borders` | off | Open edges keep their place (meshes that tile with neighbours). |
| `direction` | Auto | Auto: world +Y when every displaced surface is world-planar (the shaders' relief axis), else the smoothed normal. Normal: always the smoothed normal. Axis: `direction_axis`. |
| `hard_angle` | 30 degrees | Source normals further apart stay a hard edge in the rebuilt normals. |
| `generate_lods` | on | Godot's automatic LODs on the baked mesh. |
| `cache_directory` | `res://gads_baked` | One `<name>_<key>.mesh` per bake; the scene refers to the file. |
| `geometry_range`, `geometry_range_margin` | 0, 2 m | Beyond `geometry_range` the source mesh is drawn with the materials' parallax instead of the baked geometry, cross-faded over the margin (0: geometry at every distance). `suggest_geometry_range()` gives the distance where the relief covers about two pixels. |
| `collision` | None | Trimesh or Convex: a static body with a shape from a coarser pass (`collision_max_triangles` 20 000, tolerance x `collision_error_scale` 4), on `collision_layer` / `collision_mask`. |

**Level of detail.** Near the camera the baked geometry, with Godot's automatic LODs chosen by
screen-space error (`lod_bias` on the node, `rendering/mesh_lod/lod_change/threshold_pixels`
for the project); beyond `geometry_range` the source mesh with parallax; beyond the preset's
fade distance plain normal mapping. Each step is cheaper than the one before and the switches
cross-fade.

What the bake does: longest-edge bisection where the height field deviates from the triangles by
more than the tolerance (in world metres), worst regions first until the budget; one position
per vertex across UV seams and hard edges, so nothing cracks; where the budget stopped it, heights
filtered to each vertex's footprint so they do not alias; normals from the displaced faces;
MikkTSpace tangents. The materials stay the same:
on a baked mesh they skip the parallax march, map textures where each vertex was before it moved,
and add only the part of the normal map finer than the triangles (so the relief is not lit
twice). Details in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#9-baked-displacement-gadsmeshinstance3d).

The bake goes stale when the source mesh, a material's displacement parameters or height map, the
settings, the node's scale or rotation, or (world-planar and triplanar materials) its position
change: the inspector, a configuration warning and Validate Setup say so, and Bake picks the
change up. In code:

```gdscript
var rock := GADSMeshInstance3D.new()
rock.source_mesh = load("res://props/rock.glb::ArrayMesh_1")   # or a MeshInstance3D's mesh
rock.quality = GADSMeshInstance3D.Quality.HIGH
add_child(rock)
rock.bake()                      # blocking; bake_async() + bake_progress / bake_finished
print(rock.get_bake_summary())
```

A bake made while the game runs is not written into `res://` (read-only in an exported game): it
stays in memory, unless `cache_directory` is under `user://`.

### Debug views

`debug_view` on the node (or the demo's panel): **Hit offset** (how far the march moved each
pixel), **Cost** (red = linear + refinement steps / 64, green = triplanar planes / 3, blue = mip
level / 8), **Relief** (height at the hit), **Normals**, **Self-shadow** (the self-shadow factor
of the directional lights), **Field rings** (ring index and morph state), **Tessellation** (a
baked mesh's refinement level: blue 0, green 8, yellow 16, red 24).

## Height maps and textures

The relief is only as good as the height map. Poly Haven's CC0 sets come with float EXR
displacement maps; the repository has two tools for them (not shipped with the addon):

```
python tools/fetch_textures.py                    # the default sets, 2K, with EXR heights, md5-checked
python tools/fetch_textures.py rubble --res 4k    # any Poly Haven texture id
python tools/prepare_textures.py                  # -> demo/textures/<id>/ (the demo's copies)
python tools/prepare_textures.py --res 2048 gravel_stones rocks_ground_02
```

`prepare_textures.py` writes a single-channel half-float `<id>_height.exr` remapped to the 1st
/ 99th percentile, resized colour, normal and ARM maps, explicit `.import` settings (mipmaps
everywhere, lossless height, BC5 normal map), the Poly Haven license record and an `.gads.json`
with the real-world size and a suggested relief depth that `GADSMaterials.from_texture_set()`
reads. The default sets: gravel_stones, rocky_gravel, clean_pebbles, cobblestone_floor_03 /
07 / 08 / 13, square_cobblestone, rocks_ground_02 / 04 / 05 / 06, rubble, brick_wall_001
(plus forest_ground_04 for the demo's terrain). The demo ships nine of them at 1-2K; get the
others (or higher resolutions) from <https://polyhaven.com/textures> with the tools above.

For your own 8-bit height maps: **Project > Tools > GADS: Prepare Height
Maps** (select the images in the FileSystem dock) writes `<name>_gads_height.exr`, remapped to the
full 0-1 range, with import settings. It cannot add precision that is not there, but it stops
further loss.

## Offline hero bake (Blender)

For props whose silhouette matters (a wall end, a rock seen against the sky),
`tools/bake_displaced_mesh.py` subdivides a mesh (or a primitive) in Blender, displaces its
vertices by the height map with the same conventions as the shaders, decimates and writes a
glTF:

```
blender -b --factory-startup -P tools/bake_displaced_mesh.py -- \
    --primitive box --size 2.0,0.9,0.3 --mapping box --texture-size-m 3.0 \
    --height brick_wall_001_disp_2k.exr --height-m 0.025 --midlevel 1.0 --even-offset \
    --edge-length 0.007 --max-tris 120000 --output demo/models/hero_brick_wall.glb
```

`-- --help` lists every option; `tests/test_blender_bake.py` checks the displaced vertices
against the height map. The demo's brick wall scene shows a baked hero wall next to a POM box.

## Building the native library

The tessellator behind GADSMeshInstance3D is C++ in `native/` (not shipped with the addon),
built as a GDExtension with [godot-cpp](https://github.com/godotengine/godot-cpp) into
`addons/gads/native/bin/`. The repository holds release builds for Linux and Windows x86_64; to
rebuild them (or build for another platform), with Python, SCons and a C++17 compiler:

```
pip install scons
python tools/build_native.py                 # this platform
python tools/build_native.py linux windows   # on Linux, Windows with MinGW (x86_64-w64-mingw32-g++-posix)
```

The script fetches godot-cpp at a pinned revision into `native/godot-cpp/`. The library embeds a
hash of its sources, and the bake tests fail when the committed library was not rebuilt after a
source change. For a new platform, add its line to `addons/gads/native/gads.gdextension`.

## How it works

Details in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). In short:

- **POM** marches from the top of the relief slab down along the view ray with
  `mix(max_steps, min_steps, N.V)` linear steps, bisects the bracketing interval and finishes
  with a secant step. The mip level is computed once from the rasterized UV derivatives and
  every march sample uses it (`textureLod`). The relief depth fades to zero between the fade
  distances, and the step count with it; beyond, no march runs at all.
- **Individual stones** come from four things together: 16-bit heights (8-bit terraces into
  flat plates), a refined intersection (stones keep their round tops and sharp contacts instead
  of the stair steps of a plain linear search), self-shadowing (each stone shadows its
  neighbours in the direction of the sun, contact-hardening like real shadows) and, near the
  camera, geometry (Ultra): cobbles and rocks rise above the ground plane, stick out against what
  lies behind them at grazing views and get real depth for SSAO; gravel stones smaller than the
  grid's 4 cm stay parallax, with loose pebbles on top as real meshes.
- **The field** is a geometry clipmap of LOD rings, snapped to the camera so vertices never
  slide over the height map, with CDLOD-style geomorphing so each ring's outer edge matches the
  next ring exactly. Its fragments still march the full-resolution relief (a 4 cm grid cannot
  carry 2 cm stones), so geometry and POM agree and the grid's edge is invisible.

## Project structure

```
addons/gads/                      the addon (all that is shipped)
  core/                           GADSManager (node), GADSSettings (presets), GADSGlobals
  materials/                      GADSMaterials (variants, parameters)
  render/shaders/                 the .gdshaderinc library, field / pebble / capture shaders
  render/shaders/variants/        the 30 surface and 3 field shaders (generated)
  render/textures/gads_dfg_lut.exr  Godot's DFG table, recomputed (for the energy compensation)
  terrain/                        GADSDisplacementField3D, GADSPebbleScatter3D, GADSGroundBake
  geometry/                       GADSMeshInstance3D, GADSMeshBaker (baked displacement)
  native/                         gads.gdextension and the tessellator libraries (bin/)
  editor/                         material converter, setup validator, bake inspector
  import/                         GADSHeightTools
  plugin.gd, plugin.cfg, README.md, LICENSE.md
native/                           the tessellator's C++ sources, SConstruct (not shipped)
demo/                             demo project: scenes, UI, fly camera, CC0 texture copies, models
docs/                             ARCHITECTURE.md, RESEARCH.md, images/
tests/                            test suites, harness, benchmark, mutation runner, log scanner
tools/                            engine runner, native build, texture fetch / prepare, variant
                                  generator, DFG table, Blender bake, benchmark runner, screenshots
.github/workflows/tests.yml       CI: tests/run_all.py on Linux (Godot 4.7.2, lavapipe, Xvfb), the
                                  native build for Linux and Windows, headless suites on Windows
```

## Demo

Run the project (main scene `demo/demo_main.tscn`). Keys: **1-4** scene, **V** next camera
view (eye level, grazing, overview), **P** next preset, **B** next comparison (flat / POM /
POM + geometry), **H** hide the panel; hold the right mouse button and use **WASD/QE** to fly
(Shift fast, Alt slow). In the rocky-ground scene the boulder on the right is the left one's
mesh as a GADSMeshInstance3D, baked in the background when the scene loads (debug view
Tessellation shows its triangles).

![Demo with its panel](docs/images/demo_ui.jpg)

| | |
|---|---|
| ![Field rings](docs/images/gravel_path_field_levels.jpg) | ![March cost](docs/images/gravel_path_cost.jpg) |
| Field rings debug view (ring index and morph state) | March cost debug view (red: steps, green: triplanar planes, blue: mip level) |

Images: `tools/capture_screenshots.gd`.

## Tests

```
python tests/run_all.py              # everything below except benchmark and mutations
python tests/run_all.py --bench      # ... plus the benchmark (waits for an idle GPU)
python tests/run_all.py --mutations  # ... plus the mutation checks (slow)
python tests/run_mutations.py sign seam              # mutations whose name contains a word
python tools/godot.py --script tests/render_tests.gd -- --only=pom_matches,swim   # a subset
```

Engine runs go through `tools/godot.py`, which serialises them with a lock and finds Godot
via the `GODOT_BIN` environment variable, else `tools/.godot_path` (one line, git-ignored),
else `godot` on `PATH` (on Windows use the `*_console.exe` build). Render suites run
**headed**: `--headless` is a dummy renderer that draws nothing. Without a GPU (a Linux server,
CI) they run on Mesa's lavapipe under Xvfb, as `.github/workflows/tests.yml` does:

```
sudo apt-get install mesa-vulkan-drivers xvfb
VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json xvfb-run -a -s "-screen 0 1920x1080x24" python tests/run_all.py
```

| Suite | What it checks |
|---|---|
| shader variants | The 33 variant files in the repository are what `tools/generate_variants.py` generates. |
| logic tests (headless, 53 checks) | Variants parse back to their mapping / quality / depth write; preset table (Ultra keeps soft self-shadowing and at least Medium's parallax next to its geometry, omni and spot lights self-shadow from High up), budgets and feature switches (a switch never adds a feature); edits to a Custom preset's settings apply; presets reach GADS materials on mesh surfaces, overlays, next passes, CSG shapes, MultiMeshes, GridMaps and particles, also those added later; Validate Setup reports each mistake it knows (and nothing on a correct setup); the pebble scatter gets the field's parameters when they change and not when they do not; the ring mesh (vertex count, no triangles in the holes, every ring's outer edge collapsing exactly onto the next ring's inner edge, seam flags); morph bands inside their rings for Ultra's grid and a dense one, a new field's defaults equal Ultra's grid; the ground bake's CPU twin (`GADSGroundBake.sample()`): bilinear heights at 16-bit precision, the gradient normal, nothing displaceable at or beyond the bake's border, the edge continued smoothly beyond it, a 30-degree slope is ground and a 45-degree slope is not at 5 cm and at 20 cm texels, a 15 cm kerb is a step at 5 cm texels, a cell without ground, per-cell layers; every demo texture imported with mipmaps, heights as one-channel half float. |
| render tests (headed, 77 checks) | **POM against a CPU ray / height-field intersection** (world floor with relief above and below, UV floor, UV wall, triplanar floor and two walls; steep, 45-degree and grazing views): median hit error under 0.2 mm and 90th percentile under 0.4 mm on a 50 mm relief (measured worst 90th percentile 0.13 mm; without the bisection 1.0 mm). **Inverted `height_remap`** (1, 0) on an inverted map draws the same relief (99th percentile 0.10 mm). **World-planar walls**: finite, lit pixels (a smoke test, see the file). **No swimming**: 190 relief markers over 24 camera positions stay within 0.19 mm of their traced position. **Triplanar** marches 1 plane on a floor and 2 on a 45-degree roof. **light() vs Godot's built-in lighting** (dielectric, metal, metal at a grazing view): 99th percentile at most 0.07 %, maximum 0.17 % (limits 0.12 % / 0.3 %); the flat variant equals ORMMaterial3D exactly. **LIGHT_VERTEX**: on the 2 041 pixels whose received shadow depends on where it is computed, 100 % are lit or shadowed as on the relief. **Self-shadow** against a CPU height-field shadow: 99.8 % of 4 929 pixels agree (limit 98 %); from an omni and a spot light, against the shadow towards the light's position: 99.5 % (limit 98 %), and nothing changes with the setting off. **Depth write**: with it, props are cut where the relief (not the plane) predicts on 100 % of the 1 397 pixels where the two disagree, and 4 of 318 484 wall pixels are empty; without it, as the plane predicts and none empty. **Mip shimmer** 10-60 m away: POM flickers 1.02 x as much as flat normal mapping (limit 1.3), and the march samples the mip level the hardware would pick (90th percentile 0.006 levels off). **Distance fade**: 136 mm parallax offset before the fade, 0 beyond it. Globals (the registered defaults and this project's are the Medium preset), parameter defaults equal to the shaders' own, emission pass-through. |
| field tests (headed, 36 checks) | **Vertex heights** against the height map: 1 539 vertices in all 4 rings, largest error 0.03 mm. **Over a baked ground** (slope, kerb, hole, other ground, the bake's edge): 12 966 vertices against `GADSGroundBake.sample()`, largest error 0.20 mm. **The field's own parallax** against the CPU ray tracer: 90th percentile 0.05 / 0.07 / 0.10 mm (steep / 45 degrees / grazing); its self-shadow agrees with the CPU height-field shadow on 99.8 % of pixels. **No cracks**: 0 background pixels inside the grid from 6 camera positions. **No swimming**: 0 mm height change in the inner ring while the camera walks; in the morph bands at most 0.96 mm per 1 cm camera step (limit 2 mm). **Field vs parallax ground**: 0.15 % mean luminance difference inside the grid (limit 1 %), 0.08 % in the last metre before the relief fades (limit 0.5 %), 0 beyond the grid. **Ground bake**: 1 698 points within 1.9 mm of the mesh surface. **Pebbles stay put**: 0 of 1 536 pebble pixels change when the camera moves 1.24 m across cell boundaries. Lifetime: presets, resizes, a second viewport, freeing the scene, a scene change during a bake. All four demo scenes render at every preset, their ground faces up, and their runtime bakes take about 0.3 s (printed by the test). The demo's fly camera flies. |
| bake tests (headed, 64 checks; headless without the render comparison) | **Accuracy**: points inside the baked triangles of a 60 mm bump against the height field at the same uv: largest distance 0.47 mm at a 0.5 mm tolerance (736 triangles). **Adaptivity**: 107 times the triangle density on the bump as on the flat plane. **Closed meshes stay closed** (every edge in exactly two triangles after welding): a box with triplanar and with UV mapping (seams, hard edges), a UV sphere (seam, poles), a world-mapped cylinder (caps). Locked borders do not move (free ones by 22 mm); the budget caps the count exactly (3 000) and the statistics report the error left; identical results for repeated bakes and any thread count; scale 2 halves the object-space displacement (the tolerance is in world metres, the triangle count stays the same); a rotated plane moves along its own normal; a plane's 45-45-90 triangles stay 45-45-90 over 40 001 triangles; normals follow the slope, tangents along +u and perpendicular, `CUSTOM0` / `CUSTOM1` rest data, 7 LODs sharing the vertices; cancel stops a 5 M-triangle bake within milliseconds. **Node**: background bake with progress, the cache file the scene refers to, reuse of the cached file, Rebuild, Clear, the source untouched; staleness after a new relief depth, quality, source edit, scale, or (world mapping) position, not after moving a UV-mapped mesh; trimesh collision of its own resolution that a ray hits 0.4 mm from the relief's top, removed with collision None; a saved and reloaded scene refers to the bake and is not stale. **Render**: on the pixels where the relief shows, a baked mesh differs from the parallax render of the same material by 0.0065 (mean), the normal map applied on top of the geometry by 0.091; a baked mesh marches no parallax steps; the Tessellation view. |
| demo / editor smoke | The demo and the editor with the demo open run without script errors, engine errors or leaks. |
| standalone addon (shipped archive) | Builds the `git archive` users download (`.gitattributes` export rules applied), checks it holds only `LICENSE` and `addons/gads` with no Markdown link to a file it does not ship, puts it alone into a fresh project, lets the plugin register its globals and checks that a POM ground and a GADSDisplacementField3D with pebbles render there. |
| editor plugin actions | In a real editor: Add GADSManager Node, Add GADSDisplacementField3D, Convert Materials (a mesh and a CSG shape), Bake Ground, Make Selected Meshes GADSMeshInstance3D and Bake Selected GADSMeshInstance3D (the bake saved into `res://gads_baked/`), each with undo and redo; the inspector's Bake / Rebuild / Clear buttons; a second bake that replaces the first while it is in use; Validate Setup; Prepare Height Maps; a save that writes no internal nodes, keeps the materials' saved variant and the field's properties (the node's preset does not touch them in the editor) and refers to the bake files instead of embedding them. |
| offline Blender bake (`tests/test_blender_bake.py`) | Vertex-exact displacement against the height map for the primitives and mappings, decimation and glTF export. |
| mutation checks (`tests/run_mutations.py`) | Re-introduces one bug at a time and expects its tests to fail: height map without mipmaps, march at mip 0, wrong parallax sign, no binary refinement, world-planar rotation sign, triplanar X plane mirrored, zero-weight planes marched, no distance fade, `LIGHT_VERTEX` not written, self-shadow ray reversed, Lambert instead of Burley in `light()`, a clamped GGX term, no energy compensation, depth written by every POM variant, depth not rounded, no geomorph at ring seams, no grid snapping, vertex fetch at mip 0, relief pushed down, pebbles seeded by window slot, a bake that ignores the layers, a feature switch that adds features, an inverted remap that flattens, the field's parallax sign, the field's self-shadow direction, the field's relief measured from ground + lift, kerbs not marked (shader and CPU), ground beyond the bake displaced, local lights that never or always self-shadow, field parameters set when unchanged, a scatter that stops following its field, presets that miss CSG shapes, Custom settings not followed, the demo camera's script attached after it is ready, a baked mesh that still marches, a baked mesh lit by the full normal map on top of its slope, a bake key that ignores scale and rotation, the bake cache ignored, a collision body saved with the scene. Each prints what the failing tests measured. On the GTX 1080 the first 29 were all caught; on Mesa's lavapipe 35 of the 36 are, all but "depth not rounded": there the depth pre-pass and the colour pass agree without the rounding, so the bug it guards against does not occur. The five bake mutations added in 0.2 are all caught on lavapipe. |

Every suite fails on engine errors, script errors or leak reports ("RID ... was leaked",
"ObjectDB instance ... leaked", "resources still in use") in its log. The tests compare against
references computed independently of the shaders (a CPU ray tracer written from the documented
conventions, the height image's own mip data, Godot's own lighting, ORMMaterial3D), and the
direction tests only count pixels where the right and the wrong answer differ, so no test can
pass because two errors cancel.

## Limitations

- **No silhouettes from POM.** Walls, props and anything without a GADSDisplacementField3D keep
  their flat outline; the relief ends at the mesh's edge. Bake the few props where that shows
  (GADSMeshInstance3D).
- **Baked displacement** is an editor-time bake of static meshes: no skinned meshes (refused),
  blend shapes are dropped, and a mesh moved at runtime keeps its bake (a world-planar or triplanar
  bake then no longer matches the world-space texture; UV-mapped bakes move freely). The native
  library ships for Linux and Windows x86_64 only. Earlier bakes stay in the cache directory
  until deleted by hand. Collision is a static body.
- **The near-camera geometry needs height-field ground**: world-planar ground materials on
  terrain that is a function of XZ within the bake (no overhangs, caves, vertical walls). Slopes
  steeper than about 39 degrees between neighbouring bake texels (kerbs, steps) are left to POM:
  the field dives under the ground there. UV-mapped or triplanar ground cannot be a field layer.
- **Where the ground ends** (beyond the bake, holes in the ground) the field dives under where
  the ground would be. With nothing there to hide it, a camera at such an edge sees the field as
  a flat sheet a few centimetres below the edge; keep ground under the field's reach wherever the
  camera can go.
- **Low steps are draped.** A step counts as a step when it is higher than 0.8 x the bake texel
  size (4 cm at the default 5 cm); lower ones, and all kerbs of a coarse bake, get a ramp of
  displaced geometry in front of their face.
- **Feet sink** into the relief by up to its depth (a few centimetres): collision stays on the
  original ground. Characters' feet also cover pebbles rather than resting on them.
- **Depth write** (opt-in) costs early-Z and runs the march in the depth pre-pass. The colour
  pass keeps only fragments whose depth equals the pre-pass depth; the addon rounds the written
  depth so both separately compiled passes agree, but a few pixels per million can still
  disagree and show the background (measured: 4 of 318 484 in the render test). Disabling the
  depth pre-pass (`rendering/driver/depth_prepass/enable`) removes the problem at a cost for
  the whole scene.
- **Self-shadowing** comes from directional lights, and from omni and spot lights where the
  settings ask for it (`self_shadow_local_lights`: High and Ultra). Each local light adds a
  self-shadow march on every pixel it lights, which the measured preset costs (a sun only) do
  not include; with many overlapping local lights, use Medium or switch it off in a Custom
  preset. Area lights are shaded by the engine as usual and do not self-shadow.
  The custom `light()` omits the soft-light size term Godot applies to lights with a size
  (a few thousandths of N.L). With `force_lambert_over_burley` on, the self-shadowing variants
  still use Burley diffuse (the flat and POM variants follow the setting).
- **One camera.** Fields and scatters follow one camera (the viewport's, or `camera`); split
  screen or a second viewport sees the same grid, displaced around the first camera.
- **The ground bake** is a static height field: moving ground or ground edited at runtime needs
  a new bake (`bake_ground()`, a few frames: 0.2-0.3 s for the demo's 90 x 90 m at 5 cm texels, as
  printed by `tests/field_tests.gd`; the field is hidden meanwhile). Texels at the bake's edge
  and next to no ground are not displaced. A bake takes 8 bytes per texel (26 MB for that
  ground) in memory and on the GPU.
- **Relief within one material only.** Each ground layer is displaced by its own height map and
  blended by the bake's weights; there is no height-based blending between layers.
- **Height map precision.** 8-bit heights terrace. The Poly Haven EXRs used by the demo are
  float; other sources may not be.
- The **Mobile** and **Compatibility** renderers and XR are untested.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Shaders fail with "global uniform 'gads_pom_steps' does not exist" | Enable the plugin (it registers the shader globals), then reload the project. |
| The relief looks jagged or crawls at a distance | The height texture has no mipmaps. Reimport it with mipmaps (Validate Setup reports it). |
| Stones look like stacked plates | The height map is 8-bit. Use a 16-bit / EXR height, or Prepare Height Maps. |
| Relief goes the wrong way (stones look like holes) | `height_center` is 1 where 0 is meant, or the height map is inverted (`height_remap` = (1, 0)). |
| The field is not visible | It needs a rendering device (not `--headless`), a ground layer that is displaceable at the camera's position (Field rings debug view), and a baked or flat ground under it. Ground materials must be world-planar with `height_center` 0. |
| Props float above the relief or cut into it | Opt-in depth write on that surface; or place props on the relief's average height. |
| A preset changes nothing on some surfaces | Their material was assigned by code to a node already in the tree (the node registers materials as nodes enter the tree). Call `register_material()` with it. |
| After undoing and redoing Bake Ground, quitting the editor with the field selected prints "Can't use get_node() with absolute paths from outside the active scene tree" | Seen with Godot 4.7.2 at shutdown, after the scene was saved; nothing is lost. The cause was not found; deselecting the field before quitting avoids it. |

## Roadmap

- Height-based blending between ground layers (stones sitting in sand).
- Silhouette POM (curvature-aware) for props.
- Runtime and streaming bakes (the tessellator already runs on a worker thread), skinned meshes,
  macOS and ARM builds of the native library, a cache cleaner.
- A runtime height bake from arbitrary meshes for non-planar surfaces near the camera.

## AI-usage disclosure

This project was developed with AI assistance: design, code, shaders, tests and documentation
were written with **Claude (Anthropic)**, under the direction and review of the maintainer. All
measurements in this README come from the test and benchmark scripts in this repository, which
are named next to each figure.

## License

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 M-Rocchinotti and contributors. The demo's
textures are CC0 (Poly Haven); each set keeps its license record.

## Credits and sources

- Tatarchuk: *Dynamic Parallax Occlusion Mapping with Approximate Soft Shadows* (I3D 2006) - the
  adaptive march and contact-hardening self-shadow.
- Policarpo, Oliveira, Comba: *Real-Time Relief Mapping on Arbitrary Polygonal Surfaces* (I3D
  2005) - the binary refinement.
- Losasso, Hoppe: *Geometry Clipmaps* (SIGGRAPH 2004), Strugar: *Continuous Distance-Dependent
  Level of Detail for Rendering Heightmaps* (CDLOD, 2009) - the near-camera grid and its
  geomorphing.
- Terrain3D (MIT, Cory Petkovsek, Roope Palmroos and contributors): the camera-following
  GPU-particle cell pattern of its `extras/particle_example`, used by the pebble scatter
  (reimplemented, no code copied).
- Epic Games' UE5 documentation (Nanite displacement, "Displacement Center") for the target
  look and the height convention.
- The Godot Engine source (`scene_forward_clustered.glsl`, `light_compute`, the DFG table) -
  the custom `light()` reproduces Godot's shading; no engine code is shipped.
- Rivara: *Mesh refinement processes based on the generalized bisection of simplices* (SIAM J.
  Numer. Anal., 1984) and the longest-edge propagation path (LEPP) - the tessellator's
  refinement. Barre-Brisebois, Hill: *Blending in Detail* (2012) - Reoriented Normal Mapping,
  run backwards for the detail normals of baked meshes.
- godot-cpp (MIT) and MikkTSpace (Morten S. Mikkelsen, zlib) are compiled into the native
  library; their notices ship in `addons/gads/native/THIRDPARTY.md`.
- Poly Haven (CC0) for every demo texture. Research notes: [docs/RESEARCH.md](docs/RESEARCH.md).

## Version

0.2.0 (unreleased). See [CHANGELOG.md](CHANGELOG.md).
