# GADS - Godot Adaptive Displacement System

Adaptive surface displacement for Godot 4.7 (Forward+, Mobile and Compatibility): gravel that reads as
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
- Vector displacement maps (XYZ offsets in tangent or object space: overhangs, undercuts,
  sculpted ornaments) for baked meshes, on top of or instead of the height map.
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
- Adaptive quality: the preset and the runtime tessellation step down while frames miss a
  target time and come back when there is room; one triangle budget shared by all runtime
  tessellated meshes by screen coverage and priority.
- Relief queries for gameplay (surface height, normal, raycast on the displaced ground) and
  navigation meshes that follow terrains and baked meshes.
- Custom shader hooks (height, surface, layer masks) and six visual shader nodes (parallax UV,
  height blend, slope mask, triplanar weights, detail normal, cavity).
- Surface effects on every material (snow / dust / sand cover, wetness, puddles in the relief's
  low parts, cavity and edge colours) and a global weather (rain, snow, puddles) that the
  near-camera geometry follows too.
- Baked meshes export to glTF (.glb / .gltf) or OBJ for other tools.
- Sculpt baked meshes by hand in the viewport: raise, lower, smooth and flatten strokes on top of
  the materials' relief, undoable and baked again per stroke.
- Procedural relief without texture files: eleven tileable patterns (noise, ridged, billow, rock,
  stones, cracks, bricks, tiles, waves, ripples, craters) and normal, occlusion, curvature,
  albedo and ORM maps from any height map, as a complete material in one click.
- Editor tools: create a GADS material from a downloaded texture set (roles from file names,
  proposed depth, height converted to 16-bit EXR, ORM packed, DirectX normals converted), add
  nodes, convert StandardMaterial3D / ORMMaterial3D with a height map (undoable),
  make meshes GADSMeshInstance3D and bake them (undoable, with progress and cancel), bake the
  ground under a field, turn 8-bit height maps into 16-bit EXR, validate the setup.
- Runtime: view-dependent re-tessellation of baked meshes around the camera, and deformation
  (footprints, tracks, craters) of the near-camera geometry and the ground's parallax.
- `GADSTerrain3D`: a heightmap terrain with chunk LODs chosen by screen-space error, up to three
  height-blended GADS layers painted by a splat map or slope and height rules, HeightMapShape3D
  collision and the near-camera displacement field on its own ground data.
- A demo with seven scenes (gravel path, cobblestone street, rocky ground, brick wall and props,
  hills with a rover leaving tracks, a cliff tessellated for the camera, a material lab of
  procedural materials, surface effects and vector displacement), a flat / POM / POM + geometry
  comparison, weather and a frame-time overlay.

## Requirements

- **Godot 4.7** or newer (developed and tested on 4.7.2-stable).
- The **Forward+** renderer (Vulkan tested on Windows 10, NVIDIA GeForce GTX 1080; every test
  suite also passes on Linux with Mesa's lavapipe software Vulkan, as in CI). The **Mobile** and
  **Compatibility** renderers work too (`tests/renderer_tests.gd` on lavapipe and llvmpipe:
  every variant, the field, pebbles, terrain, depth write and deformation); their performance is
  not measured. On Compatibility the near-camera field cannot capture the ground at runtime: it
  needs a ground bake saved from the editor (Bake Ground with Forward+ or Mobile) and stays off
  without one; a GADSTerrain3D makes its own ground data and works there.
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
2. Enable **GADS** in Project > Project Settings > Plugins. It registers eight
   global shader uniforms (`gads_pom_steps`, `gads_pom_range`, `gads_shadow`, `gads_debug`, `gads_dfg`,
   and `gads_deform`, `gads_deform_params`, `gads_deform_time` for runtime deformation) in
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
| `cover_amount`, `cover_color`, `cover_roughness`, `cover_slope`, `cover_height_bias`, `cover_sharpness` | 0, snow white, 0.65, (0.35, 0.75), 0.5, 8 | Optional cover (snow, dust, sand) on surfaces facing up (`cover_slope`: band of the world normal's y), on relief tops first (`cover_height_bias` > 0) or hollows first (< 0). Off at 0. |
| `wetness`, `puddle_level` | 0, 0 | Wet surfaces (darker, glossier) and puddles: flat water where the relief lies below `puddle_level` (0..1 of the height map) on level ground. Off at 0. |
| `cavity_amount`, `cavity_color`, `edge_amount`, `edge_color`, `cavity_radius` | 0, dark brown, 0, light, 3 | A colour in the relief's hollows (dirt, moss) and on its crests (wear), measured against the relief within `cavity_radius` mip levels around. Off at 0. |
| `effects_vertex_mask`, `weather_response` | None, 1 | Limit the effects to a painted vertex colour channel; how much the GADSManager weather (rain, snow, puddles) affects this material. |
| `vector_displacement_texture`, `vector_displacement_m` | black, 0 | UV mapping: an optional vector displacement map (an XYZ offset per texel, as sculpting tools export them), times `vector_displacement_m` metres. Moves vertices in a `GADSMeshInstance3D` bake only (overhangs a height map cannot make); parallax and plain meshes ignore it. Off at 0. |
| `vector_displacement_space` | Tangent | Tangent: x along +u, y along the texture's up (-v), z along the surface normal (OpenGL convention). Object: the node's own axes and units. |
| `vector_displacement_signed` | off | On: texel values are the offsets (an EXR / HDR map, -1..1 or beyond). Off: 0..1 maps to -1..1 (an 8-bit map, 0.5 is no offset). |

#### From a downloaded texture set

Select the images of a texture set in the FileSystem dock (as downloaded from Substance, Quixel,
Poly Haven, ambientCG or baked in Blender: `Rock_BaseColor.png`, `Rock_Normal.png`,
`Rock_Roughness.png`, `Rock_Height.png`, `Rock_AO.png` ..., several sets at once) and run
**Project > Tools > GADS: Create Material from Selected Textures**. GADS tells each file's role
from its name (BaseColor / Albedo / Diffuse, Normal with OpenGL or DirectX convention,
Roughness, Metallic, AO, ORM / ARM, Height / Displacement), shows each set with a proposed texture
size, relief depth (3.5 % of the size: 7 cm for 2 m) and mapping, and on **Create** writes what the
set lacks for GADS next to it (`<name>_gads_height.exr`: the height remapped to its 1st / 99th
percentiles as a 16-bit EXR with mipmaps; `<name>_gads_orm.png`: AO, roughness and metallic packed;
`<name>_gads_normal.png`: a DirectX normal map converted to OpenGL), imports them and saves
`<name>_gads.tres`. `GADSTextureSet` does the same from scripts (`detect()`, `recommend()`,
`prepare()`, `create_material()`).

#### Surface effects and weather

Every GADS material has optional surface effects: **cover** (snow, dust, sand) on what faces up,
tops of the relief first; **wetness** and **puddles** that fill the relief's low parts with flat
water on level ground; **cavity** and **edge** colours in the hollows and on the crests. They change
only the shading (albedo, roughness, metallic, occlusion, and how much of the normal map and the
self-shadow show: snow and water fill the relief), never the relief or a bake, and cost nothing
while off. The GADSManager node's **Weather** (`rain_wetness`, `snow_cover`, `puddle_level`, or
`set_weather(rain, snow, puddles)`) applies them to every GADS material at once, each scaled by
its `weather_response`; the near-camera field and its pebbles follow their layers' effects and
the weather, so the ground looks the same near and far (tests). In the demo, **R** cycles dry,
rain, snow and thaw.

```gdscript
GADSManager.find_in(get_tree()).set_weather(0.8, 0.0, 0.3)   # rain with puddles
material.set_shader_parameter("cavity_amount", 0.6)          # moss in the cracks
material.set_shader_parameter("cavity_color", Color(0.18, 0.25, 0.1))
```

#### Procedural materials (no texture files)

**Project > Tools > GADS: Generate Procedural Material...** makes a complete material from a
pattern: noise, ridged, billow, rock, stones, cracks, bricks, tiles, waves, ripples or craters.
Pick the kind, size (256 to 2048 px), seed, features per tile, tile size, relief depth and
mapping; GADS writes `<name>_height.exr` (half float with mipmaps), `<name>_normal.png`,
`<name>_albedo.png` (two colours by height, darker where occluded and in hollows) and
`<name>_orm.png` (occlusion from the relief's horizon, roughness lower on crests) into the
folder, imports them and saves `<name>_gads.tres`. Every map tiles without a seam; the same seed
gives the same maps everywhere. A 512 px set takes well under a second (native code, all cores).

From scripts, `GADSProcedural` gives the same in memory or on disk:

```gdscript
$Wall.material_override = GADSProcedural.create_material("bricks", {"params": {"seed": 3}, "tile_m": Vector2(2, 2)})
var height := GADSProcedural.height_image("craters", 1024, {"scale": 6, "count": 20})   # FORMAT_RF, 0..1
var normals := GADSProcedural.normal_image(height, 0.05, Vector2(4, 4))                 # any height map
var ao := GADSProcedural.ao_image(height, 0.05, Vector2(4, 4))
GADSProcedural.write_texture_set("stones", "res://textures/pebbles", "pebbles", {"size": 1024})
```

`normal_image()`, `ao_image()` and `curvature_image()` work on any height map (a scan, a sculpt),
so they also bake the maps a height map alone lacks. Generator parameters: `seed`, `scale`
(features per tile), `octaves`, `gain`, `lacunarity`, `warp`, `width` (gaps, mortar, cracks),
`bevel`, `variation`, `aspect` (bricks), `roughness` (fine noise), `sharpness` (wave crests),
`count` (craters, ripples); `GADSProcedural.PRESETS` holds each kind's defaults.

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

#### Custom shaders: hooks

Three hooks change a part of the GADS surface shader without replacing it. Define the macro and
the function, in this order:

```glsl
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;
#define GADS_MAPPING_UV
#define GADS_POM
#define GADS_CUSTOM_HEIGHT
#define GADS_CUSTOM_SURFACE

uniform float erosion = 0.0;
// Reshapes the remapped main height (0..1) wherever it is read: march, self-shadow, effects.
// Before the library; it may use its own uniforms.
float gads_custom_height(vec2 uv, float h) {
	return h * (1.0 - erosion) + erosion * h * h;
}

#include "res://addons/gads/render/shaders/gads_core.gdshaderinc"

uniform vec4 paint : source_color = vec4(0.6, 0.1, 0.1, 1.0);
// After the textures and surface effects; it may use the library's uniforms and functions.
void gads_custom_surface(vec2 uv, vec3 world_pos, vec3 world_normal, float height,
		inout vec3 albedo, inout float roughness, inout float metallic, inout float ao) {
	albedo = mix(albedo, paint.rgb, smoothstep(0.2, 0.0, height) * 0.8);   // paint in the gaps
}

#include "res://addons/gads/render/shaders/gads_surface.gdshaderinc"
```

`GADS_CUSTOM_LAYER_MASKS` with `vec2 gads_custom_layer_masks(vec2 masks, vec3 world_pos, vec3
world_normal)` reshapes the layered variants' layer masks (procedural, world position, gameplay
data). Hooks shape parallax and shading; a GADSMeshInstance3D bake reads the height texture
itself, so a height hook does not reach baked geometry. With the hooks idle the shader draws
exactly like the GADS variant (tests).

#### Visual shaders

The GADS category of the visual shader editor has six nodes: **GADSParallaxUV** (parallax
occlusion mapping of a height map: the uv where the view ray hits the relief, and the height
there; sample the other textures at that uv), **GADSHeightBlend** (the height-aware weight of a
layer over the one below for a mask), **GADSSlopeMask** (how much the surface faces up, as a
band), **GADSTriplanarWeights** (projection weights with negligible planes dropped),
**GADSDetailNormal** (Reoriented Normal Mapping of a detail normal map onto a base one) and
**GADSCavity** (cavity and edge masks from a height map). They are the same functions the GADS
materials use.

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
| `adaptive_quality`, `target_frame_ms`, `adaptive_min_preset` | off, 16.6 ms, Low | Lower the quality while frames are too slow, restore it when there is room (below). |
| `runtime_triangle_budget` | 0 | One triangle budget shared by all view-dependent GADSMeshInstance3D nodes (0: each has its own). |
| `platform_caps`, `simulate_platform` | phones and browsers: Low | The highest preset per platform or renderer while the game runs; test as another platform. |
| `rain_wetness`, `snow_cover`, `puddle_level` | 0 | The weather: surface effects on every GADS material (see Surface effects and weather). |
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

**Platforms.** `platform_caps` caps the preset where the hardware cannot afford more: keys are
OS feature tags (`mobile`, `web`, `android`, `ios`, `macos`, `windows`, `linuxbsd`) or renderers
(`forward_plus`, `mobile_renderer`, `gl_compatibility`), values the highest preset there; the
lowest cap that applies wins, Custom is never capped. By default phones and browsers run Low.
`simulate_platform = ["mobile"]` tests that on a desktop. `get_capabilities()` reports the
renderer, whether the native library (bakes, runtime tessellation, procedural maps) and a
rendering device (the fields' runtime ground capture) are there, the tags and the cap. Whatever
is missing falls back on its own: a mesh that cannot bake draws its source with parallax, a field
without ground data stays off, and every material keeps at least normal mapping.

**Adaptive quality and runtime budgets.** With `adaptive_quality` on, the node watches the main
viewport's GPU time (the frame time where the renderer does not measure it) against
`target_frame_ms` and lowers the quality when frames are too slow: a step after the target has
been missed for `adaptive_down_seconds` (1 s; a single slow frame does nothing), a step back up
after `adaptive_up_seconds` (4 s) under 80 % of it, a second between steps. Each step lowers the
preset by one, down to `adaptive_min_preset`, and makes view-dependent meshes tessellate 1.5
times coarser, for up to four steps; it never goes above `preset`, and switching it off restores
the preset at once. `quality_adapted(level)` reports each step; `adapt_to(frame_ms, delta)` takes
a game's own measurement instead. `runtime_triangle_budget` shares one triangle budget among all
view-dependent GADSMeshInstance3D nodes, by how much of the view each covers times its
`displacement_priority` (0-100), each capped by its own `view_max_triangles` (what a capped node
leaves goes to the others) and at least 1 000.

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

**Gameplay on the relief.** Physics collides with the ground mesh, so feet and props would sink
into the relief by up to its depth. The field answers where the drawn surface is:
`get_surface_height(position)` (ground plus the layers' relief at full resolution, minus the
runtime deformation; the CPU twin of what it draws near the camera, NAN off its ground data),
`get_surface_normal(position)` and `raycast_surface(from, to)` (`{"position", "normal"}` of the
first hit on the relief, for picking and projectiles). `GADSTerrain3D.get_surface_height()` uses
its detail field where it displaces and the triangles elsewhere. Use them for foot IK, decals,
particles and footstep placement.

**Navigation.** A NavigationRegion3D bakes from what is really there: GADSTerrain3D chunks (meshes
or, with parsed geometry "static colliders", their HeightMapShape3D) and GADSMeshInstance3D bakes
(their mesh, or their collision shape); the field adds nothing (its mesh is placed by its
shader). A GADSMeshInstance3D with a `geometry_range` also has its parallax fallback (the source
mesh) as a child: bake navigation from static colliders there, or with the range at 0.

### GADSPebbleScatter3D

A child of a GADSDisplacementField3D. `density`, `radius` (8 m), `per_cell` (24), `cell_size` (1 m),
`size_range` (1.2-3.5 cm), `valley_bias` (preference for low points of the height map) and
`layer_density` (per field layer, default only layer 0).

### GADSTerrain3D

A heightmap terrain built from GADS pieces. Add the node, give it a `heightmap` (red channel,
0..1 over `height_scale` metres; a 16-bit PNG or an EXR), a `size` and up to three `layers`
(GADS materials with the world-planar mapping and `height_center` 0, e.g. ground, rock, snow):

- **Geometry**: chunks of `chunk_quads` quads at `vertex_spacing`, each with index LODs at every
  power of two (`lod_levels`), keyed by their largest height error in metres, so Godot's mesh LOD
  picks the coarsest one that stays under a pixel (`rendering/mesh_lod/lod_change/threshold_pixels`).
  Skirts as deep as twice the largest error hang from every chunk's border and hide the seams
  between chunks at different LODs. The chunks are internal children built when the node enters
  the tree, natively when the GADS library is loaded (the GDScript builder otherwise; 256 m at
  1 m spacing with its detail field in about 0.16 s), never saved with the scene.
- **Layers**: combined into one layered GADS material (`GADSMaterials.combine_layers()`, or your
  own `material`): the first everywhere, the second and third on top where `splatmap` (R, G) puts
  them, else by rules: `slope_layer` on slopes steeper than `slope_range` (degrees; rock on
  cliffs), `height_layer` above `height_band` (m; snow on peaks). Within a layer's mask the higher
  relief wins (height-aware blending).
- **Collision**: a HeightMapShape3D of the same grid and triangulation (`collision`,
  `collision_layer`, `collision_mask`).
- **Painting** at runtime: `paint_layer(position, radius, layer, strength, falloff)` paints the
  second or third layer (0 erases back to the rules or splat map) with a soft edge; the chunks'
  vertex colours and the detail field's ground data follow, chunks streamed in later carry it,
  and `get_painted_weights()` / `set_painted_weights()` save it. The demo's rover lays a gravel
  trail this way.
- **Sculpting and painting** in the editor: **Sculpt / Paint** at the top of the inspector, then
  left-drag in the 3D viewport raises, lowers, smooths or flattens the ground or paints the second
  or third layer (or the first back) under a round brush that the viewport outlines on the ground
  (radius in metres, strength in centimetres per dab). Each stroke is one undoable step and
  rebuilds only the chunks it touches, their collision and the detail field's ground data under
  it. The first stroke makes `heightmap` (or `splatmap`) an editable map of one texel per vertex
  with the same heights (weights: the rules and what was painted are kept in it), saved into
  `data_directory` (`<scene>_<node>_height.res`, `_splat.res`); undoing that stroke gives the
  original map back. The same works while the game runs: `sculpt(position, radius, mode,
  strength)` digs craters and trenches, `paint_splatmap()` paints, `intersect_ray()` finds where a
  ray meets the ground without physics.
- **Roads and paths**: add a **GADSTerrainPath3D** under the terrain, draw its curve, press
  **Apply to Terrain**: the ground along it becomes a flat band `width` metres wide that fades back
  over `falloff`, following the hills (`conform`: the terrain's heights under the curve averaged
  over `smoothing` metres) or the curve's own heights, with a `layer` painted under it (gravel,
  mud). One undoable action; `GADSTerrain3D.flatten_path(points, width, falloff, layer)` does the
  same from a script (tracks a game lays at runtime).
- **Generate, erode, export** (inspector, each undoable; or from scripts): `generate_heights(kind,
  params)` makes a landscape from a GADSProcedural kind (ridged mountains, noise hills, billowy
  dunes, craters; seed and features across the terrain); `erode(params)` runs native hydraulic
  erosion (water droplets carve gullies and fill valleys; one per two vertices by default) and
  thermal erosion (steep slopes slide into scree at a talus angle), at the terrain's own scale:
  the vertex spacing and `height_scale` make the slopes physical. `export_heightmap(path)` writes
  the heights to a float EXR for other tools. `GADSProcedural.erode_image()` erodes any height
  map (`wrap` for tileable ones).
- **Streaming** (`stream_radius`, `stream_camera`): for terrains of kilometres, only the chunks
  within `stream_radius` of the camera exist. They are built on worker threads as the camera
  moves (nearest first, four at a time, at most two added per frame) and freed once well beyond
  the radius (1.25 x radius + a chunk, so a camera at the edge does not rebuild them back and
  forth), each with its own HeightMapShape3D; heights are read from the heightmap as needed
  instead of for the whole terrain. The detail field gets its ground data in a window around the
  camera (four times its reach plus 16 m), rebuilt on a worker thread when the camera has moved
  a quarter of it. `get_height()` answers everywhere, built or not. A streamed chunk is the same
  as the whole terrain's (tested).
- **Occluders**: with `occluders` each chunk gets an ArrayOccluder3D (its grid at about
  `occluder_quads` quads a side, lowered by that grid's largest error so it never hides visible
  ground), so hills hide what lies behind them once occlusion culling is on (Project Settings >
  Rendering > Occlusion Culling).
- **Detail**: with `detail_field` a GADSDisplacementField3D on the terrain's own ground data
  (heights of the finest LOD and the dominant layer, at half the vertex spacing) displaces the
  layers' height maps into real geometry around the camera. A `GADSDeformationField` in the
  scene presses both the field and the layers' parallax; `get_height()` is the
  `ground_height` a `GADSDeformer3D` needs.

```gdscript
var terrain := GADSTerrain3D.new()
terrain.heightmap = load("res://terrain/height.exr")
terrain.size = Vector2(512, 512)
terrain.height_scale = 80.0
terrain.layers = [grass, rock, snow]
add_child(terrain)
var y := terrain.get_height(player.global_position)   # the drawn surface's height
var hit := terrain.intersect_ray(from, direction)      # Vector3.INF when it misses
terrain.sculpt(hit, 3.0, GADSSculpt.Mode.LOWER, 1.5)   # a crater 1.5 m deep
```

The detail field and deformation work in world space: keep the terrain unrotated and unscaled
(moving it is fine; `rebuild()` refreshes the ground data).

### GADSDeformationField (runtime deformation)

Footprints, tyre tracks, ruts and craters in snow, sand and mud. A `GADSDeformationField` holds
how far the ground is pressed down (m; negative = raised) over a square window that follows a
node (`follow`: the player or camera; marks keep their place while inside the window). Gameplay
writes it:

```gdscript
var snow: GADSDeformationField = $DeformationField
snow.stamp(foot.global_position, 0.08, 0.05)                    # radius, depth (m)
snow.stamp(impact, 1.2, 0.4, 0.15, GADSDeformationField.Combine.ADD)  # a crater with a rim
snow.stroke(wheel_last, wheel.global_position, 0.25, 0.06)       # a tyre track
snow.stamp_image(foot.global_position, footprint_img, Vector2(0.12, 0.3), heading, 0.04)
var sink := snow.get_depth(foot.global_position)                 # the same depth, for scripts
```

or a `GADSDeformer3D` on each foot or wheel stamps by itself as it moves (`spacing`, round
marks, `continuous` tracks or an `image` turned along the direction of travel; `set_contact()` or
a `ground_height` callable say when it touches). `Combine` DEEPEN keeps the deeper of mark and
ground (snow), ADD digs (craters), SET levels. `recovery_rate` refills marks over time (computed in
the shaders from each mark's time, so free per frame); `get_state()` / `save_to()` keep them.

What reads it: a `GADSDisplacementField3D` moves its vertices and marches the deformed relief
(true geometry near the camera); world-planar GADS materials and the tops of triplanar ones
press their parallax down by the depth under each pixel (UV-mapped ones as far as they face up).
`max_depth` clamps the marks and deepens the field's slab. Size and resolution: 16 m at 512
texels (3 cm) by default; the whole map is uploaded once per frame in which it changed
(`resolution`^2 x 8 bytes).

### GADSMeshInstance3D (baked displacement)

A MeshInstance3D whose GADS materials' relief is baked into real geometry. Make one from a
selected mesh (**Project > Tools > GADS: Make Selected Meshes GADSMeshInstance3D**, undoable: the
mesh becomes `source_mesh`) or add the node and set `source_mesh`. The inspector shows **Bake**
(reuses a cached bake of the same inputs), **Rebuild** (ignores the cache), **Clear** (back to
the source mesh), **Cancel**, **Diagnose** (draws the source mesh's open, non-manifold, UV-seam,
hard and surface-border edges over it and sums them up: `GADSMeshDiagnostics`), a progress bar
and the bake's statistics; bakes run on a worker thread and are undoable. **Bake Selected GADSMeshInstance3D** in Project > Tools bakes several.

| Property | Default | Meaning |
|---|---|---|
| `source_mesh` | - | The mesh to displace; never modified. Any triangle mesh, any number of surfaces (each displaced by its own GADS material; surfaces without one are kept and refined only along shared edges). |
| `quality` | Medium | Draft / Low / Medium / High / Ultra: tolerance 5 / 2.5 / 1.25 / 0.6 / 0.3 % of the deepest relief (`height_m`), budget 25 k / 75 k / 200 k / 500 k / 1.5 M triangles. Custom: `custom_max_error` (m) and `custom_max_triangles`. |
| `min_edge_texels` | 1 | No edge is split below this many height-map texels. |
| `lock_borders` | off | Open edges keep their place (meshes that tile with neighbours). |
| `direction` | Auto | Auto: world +Y when every displaced surface is world-planar (the shaders' relief axis), else the smoothed normal. Normal: always the smoothed normal. Axis: `direction_axis`. |
| `hard_angle` | 30 degrees | Source normals further apart stay a hard edge in the rebuilt normals. |
| `generate_lods` | on | Godot's automatic LODs on the baked mesh. |
| `cluster_triangles` | 0 | Split the bake into spatial clusters of at most this many triangles, each its own instance with its own LODs (below). 0: one mesh. |
| `cache_directory` | `res://gads_baked` | One `<name>_<key>.mesh` per bake; the scene refers to the file. |
| `geometry_range`, `geometry_range_margin` | 0, 2 m | Beyond `geometry_range` the source mesh is drawn with the materials' parallax instead of the baked geometry, cross-faded over the margin (0: geometry at every distance). `suggest_geometry_range()` gives the distance where the relief covers about two pixels. |
| `collision` | None | Trimesh or Convex: a static body with a shape from a coarser pass (`collision_max_triangles` 20 000, tolerance x `collision_error_scale` 4), on `collision_layer` / `collision_mask`. |
| `view_dependent`, `pixel_error`, `view_refresh`, `view_max_triangles`, `view_camera` | off, 1 px, 0.25, 150 k, - | Runtime tessellation for the camera (below). |

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

**On import.** The scene import options (Import dock, or Advanced Import Settings) have a GADS
section: `convert_materials` turns height-mapped StandardMaterial3D / ORMMaterial3D into GADS
materials (`metres_per_repeat` sets the depth, as Convert Materials does), and `meshes` turns the
meshes named `*-gads` (the suffix is dropped, like Godot's own `-col` hints), or every mesh that
draws a GADS material, into GADSMeshInstance3D, baked during the import at `quality` with the
bake stored in the imported scene (`bake`). `GADSImportTools.process(scene, options)` does the same
to any scene from a script.

**Export.** **Export** in the inspector (or `export_baked(path)`) writes the bake to a `.glb`,
`.gltf` or `.obj` (with a `.mtl` and the textures as PNG) for other tools: every cluster as its own
object, positions, normals, UVs (and tangents and colours in glTF), the node's materials as plain
PBR materials (albedo, normal map, roughness / metallic / occlusion from the ORM texture, UV
scale and offset; the relief is in the geometry, so the height map is left out). Read back, a
glTF is the same triangles at the same positions, facing the same way (tests).
`GADSMeshExporter.export_meshes()` does the same for any meshes.

**Sculpt.** **Sculpt** in the inspector paints the surface by hand in the 3D viewport: left-drag
raises, lowers, smooths or flattens it under a round brush (radius in metres, strength in
millimetres per dab, a smooth falloff), and each stroke is one undoable step that bakes again
when it ends. The strokes go into `sculpt_map`, a float image (metres along the displacement
direction) in the source mesh's own first UVs, saved next to the bakes
(`<cache_directory>/<name>_sculpt.res`) and added to the materials' relief by the bake; a mesh
with no GADS material can be sculpted too. **Clear Sculpt** removes it. From a script:

```gdscript
GADSSculpt.dab(rock.get_sculpt_image(), uv, 0.05, GADSSculpt.Mode.RAISE, 0.01)
rock.sculpt_changed()          # stores the map and bakes again
var hit := GADSSculpt.pick(rock.mesh, local_origin, local_direction)   # the uv under a ray
```

The sculpt shapes the bake (and runtime tessellation) only: the parallax fallback past
`geometry_range` does not show it, and UVs that overlap get the same strokes. While the tool is
on, the viewport outlines the brush on the surface under the mouse.

**Cleaning the cache.** Each bake is a file named after its inputs, so changing a material, the
quality or the mesh leaves the earlier bake behind. Project > Tools > **GADS: Clean Bake Cache...**
lists the bakes, collision shapes and sculpt maps in the cache directories that no scene or
resource refers to and nothing open holds (the undo history included), and moves them to the
trash; `GADSBakeCache.find_unused()` / `remove()` from a script. Save your scenes first: a bake
an unsaved scene dropped is kept until then. A bake that only a script loads by its path counts
as unused.

**Skinned meshes.** A skinned mesh (a character, a creature) bakes like any other: the new
vertices get the bone weights interpolated from the source vertices (the strongest 4 or 8
influences, as the source has, normalised), so the baked mesh deforms with the node's `skin` and
`skeleton`, its clusters and parallax fallback too. Bake in the rest pose; textures stay on the
skin (they are mapped at each vertex's rest position). Export writes the geometry without the
skin.

**Clusters.** A large mesh baked as one piece is culled as one piece and gets one LOD for all of
it, however close the camera is to one end. With `cluster_triangles` the bake is split into
compact clusters (median splits along the longest axis: 2 000 to 4 000 triangles each for 4 000)
that the engine culls and picks LODs for one by one; Godot's LOD generator keeps the clusters'
borders, so neighbours at different LODs do not crack. The clusters are the same triangles as the
unsplit bake (tested), saved in the same cache file; the node draws the first, internal children
the others, and they follow its materials, shadow and visibility settings. With a
`geometry_range` they all switch to the parallax fallback at once, by the fallback's distance.

**Runtime (view-dependent) tessellation.** With `view_dependent` on, the node tessellates again
in the background while the game runs, for the camera's position: dense where the camera looks
closely, coarser with distance, so the error stays under `pixel_error` pixels on screen (the
quality's tolerance is the finest it goes; `view_max_triangles` is the budget). A new mesh is
made once the camera moved `view_refresh` (a quarter) of its distance to the mesh, or zoomed,
and replaces the old one when it is ready; the editor bake shows until the first one is. Large
meshes the camera gets close to and far from (terrain patches, cliffs) need far fewer triangles
this way than with one fixed bake (a third or less in the test); small props are better off with
a bake and LODs. Runtime meshes are never saved, and the collision shape stays the editor bake's.
`view_tessellated(stats)` follows each one; `refresh_view()` forces one (after a teleport).

### Profiler and optimization

The **GADS** bottom panel in the editor measures the edited scene (`GADSProfiler.collect()`):
baked meshes with their triangles, source triangles, screen coverage (from the editor camera),
memory and state; the totals (generated and active triangles, collision triangles, memory, the
cache directory's size, parallax surfaces, field triangles, the preset); and recommendations,
each with a **Fix** button where one applies: bake an unbaked or stale mesh, give a dense mesh
that covers little of the screen a `geometry_range`, raise the quality of a bake the triangle
budget cut short, use a smaller height map where the map holds no finer relief
(`GADSHeightTools.analyse_detail()`: relief per mip band). **Optimize for Target** (Cinematic,
High-end PC, Mainstream PC, Handheld, Mobile) sets the GADSManager preset and every baked mesh's
`geometry_range`: settings only, nothing is re-baked, and it is undoable.

At runtime, add a `GADSStatsOverlay` (a CanvasLayer) for the same numbers plus the frame's fps,
GPU time, draw calls and video memory; the demo shows it on **G**.

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
  core/                           GADSManager (node), GADSSettings (presets), GADSGlobals,
                                  GADSProfiler, GADSStatsOverlay
  materials/                      GADSMaterials (variants, parameters), GADSProcedural
  render/shaders/                 the .gdshaderinc library, field / pebble / capture shaders
  render/shaders/variants/        the 30 surface and 3 field shaders (generated)
  render/textures/gads_dfg_lut.exr  Godot's DFG table, recomputed (for the energy compensation)
  terrain/                        GADSTerrain3D, GADSDisplacementField3D, GADSPebbleScatter3D,
                                  GADSGroundBake, GADSDeformationField, GADSDeformer3D,
                                  GADSTerrainPath3D, GADSTerrainEdit
  geometry/                       GADSMeshInstance3D, GADSMeshBaker (baked displacement),
                                  GADSMeshDiagnostics, GADSMeshExporter, GADSSculpt
  native/                         gads.gdextension and the native libraries (bin/): tessellator,
                                  height generator
  editor/                         material converter, setup validator, bake inspector, profiler
                                  panel, scene import plugin
  import/                         GADSHeightTools, GADSTextureSet, GADSImportTools
  visual_shader/                  the GADS visual shader nodes
  plugin.gd, plugin.cfg, README.md, LICENSE.md
native/                           the native C++ sources (tessellator, height generator),
                                  SConstruct (not shipped)
demo/                             demo project: scenes, UI, fly camera, CC0 texture copies, models
docs/                             ARCHITECTURE.md, RESEARCH.md, images/
tests/                            test suites, harness, benchmark, mutation runner, log scanner
tools/                            engine runner, native build, texture fetch / prepare, variant
                                  generator, DFG table, Blender bake, benchmark runner, screenshots
.github/workflows/tests.yml       CI: tests/run_all.py on Linux (Godot 4.7.2, lavapipe, Xvfb), the
                                  native build for Linux and Windows, headless suites on Windows
```

## Demo

Run the project (main scene `demo/demo_main.tscn`). Keys: **1-7** scene, **V** next camera
view (eye level, grazing, overview), **P** next preset, **B** next comparison (flat / POM /
POM + geometry), **R** next weather (dry, rain with puddles, snow, thaw; surface effects on
every material and the near-camera ground), **C** dig a crater where the view points (hills
scene: runtime terrain sculpting), **H** hide the panel, **G** the GADS profiler overlay; hold the right mouse button and use **WASD/QE** to fly
(Shift fast, Alt slow). In the rocky-ground scene the boulder on the right is the left one's
mesh as a GADSMeshInstance3D, baked in the background when the scene loads (debug view
Tessellation shows its triangles). The hills scene is a GADSTerrain3D (ground, rock on slopes,
gravel on the tops, a gravel road to the ridge made by a GADSTerrainPath3D) with a rover driving a loop: its two GADSDeformer3D press tracks into a
GADSDeformationField, into the field's geometry near the camera and the terrain's parallax
beyond, and they fill in slowly (`recovery_rate`); it also paints a gravel trail into the
terrain's layers. The cliff is a GADSMeshInstance3D tessellated for the camera while the demo
runs (`view_dependent`: about 90 000 triangles seen from its foot, more when it fills the view
from further out) and split into clusters; walk along its foot to see the displaced outline.
The material lab is made without texture files: a procedural tile floor with dirt in the joints
and worn edges, a procedural brick wall with moss in the joints, five baked spheres (rock,
stones, craters, cracks, ridged) and a panel whose vector displacement curls into overhanging
ridges (view Grazing).

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
| logic tests (headless, 119 checks) | Variants parse back to their mapping / quality / depth write; preset table (Ultra keeps soft self-shadowing and at least Medium's parallax next to its geometry, omni and spot lights self-shadow from High up), budgets and feature switches (a switch never adds a feature); edits to a Custom preset's settings apply; presets reach GADS materials on mesh surfaces, overlays, next passes, CSG shapes, MultiMeshes, GridMaps and particles, also those added later; Validate Setup reports each mistake it knows (and nothing on a correct setup); the pebble scatter gets the field's parameters when they change and not when they do not; the ring mesh (vertex count, no triangles in the holes, every ring's outer edge collapsing exactly onto the next ring's inner edge, seam flags); morph bands inside their rings for Ultra's grid and a dense one, a new field's defaults equal Ultra's grid; the ground bake's CPU twin (`GADSGroundBake.sample()`): bilinear heights at 16-bit precision, the gradient normal, nothing displaceable at or beyond the bake's border, the edge continued smoothly beyond it, a 30-degree slope is ground and a 45-degree slope is not at 5 cm and at 20 cm texels, a 15 cm kerb is a step at 5 cm texels, a cell without ground, per-cell layers; every demo texture imported with mipmaps, heights as one-channel half float. **Erosion**: thermal erosion of a 50-degree cone settles at the 30-degree talus angle (32.7 measured) keeping its material, and the same cone at a third of the height (22 degrees) stays as it is; water erosion takes the highest tenth of noise hills down and fills the lowest tenth; the same seed erodes the same way. |
| render tests (headed, 109 checks) | **POM against a CPU ray / height-field intersection** (world floor with relief above and below, UV floor, UV wall, triplanar floor and two walls; steep, 45-degree and grazing views): median hit error under 0.2 mm and 90th percentile under 0.4 mm on a 50 mm relief (measured worst 90th percentile 0.13 mm; without the bisection 1.0 mm). **Inverted `height_remap`** (1, 0) on an inverted map draws the same relief (99th percentile 0.10 mm). **World-planar walls**: finite, lit pixels (a smoke test, see the file). **No swimming**: 190 relief markers over 24 camera positions stay within 0.19 mm of their traced position. **Triplanar** marches 1 plane on a floor and 2 on a 45-degree roof. **light() vs Godot's built-in lighting** (dielectric, metal, metal at a grazing view): 99th percentile at most 0.07 %, maximum 0.17 % (limits 0.12 % / 0.3 %); the flat variant equals ORMMaterial3D exactly. **LIGHT_VERTEX**: on the 2 041 pixels whose received shadow depends on where it is computed, 100 % are lit or shadowed as on the relief. **Self-shadow** against a CPU height-field shadow: 99.8 % of 4 929 pixels agree (limit 98 %); from an omni and a spot light, against the shadow towards the light's position: 99.5 % (limit 98 %), and nothing changes with the setting off. **Depth write**: with it, props are cut where the relief (not the plane) predicts on 100 % of the 1 397 pixels where the two disagree, and 4 of 318 484 wall pixels are empty; without it, as the plane predicts and none empty. **Mip shimmer** 10-60 m away: POM flickers 1.02 x as much as flat normal mapping (limit 1.3), and the march samples the mip level the hardware would pick (90th percentile 0.006 levels off). **Distance fade**: 136 mm parallax offset before the fade, 0 beyond it. Globals (the registered defaults and this project's are the Medium preset), parameter defaults equal to the shaders' own, emission pass-through. |
| field tests (headed, 56 checks) | **Vertex heights** against the height map: 1 539 vertices in all 4 rings, largest error 0.03 mm. **Over a baked ground** (slope, kerb, hole, other ground, the bake's edge): 12 966 vertices against `GADSGroundBake.sample()`, largest error 0.20 mm. **The field's own parallax** against the CPU ray tracer: 90th percentile 0.05 / 0.07 / 0.10 mm (steep / 45 degrees / grazing); its self-shadow agrees with the CPU height-field shadow on 99.8 % of pixels. **No cracks**: 0 background pixels inside the grid from 6 camera positions. **No swimming**: 0 mm height change in the inner ring while the camera walks; in the morph bands at most 0.96 mm per 1 cm camera step (limit 2 mm). **Field vs parallax ground**: 0.15 % mean luminance difference inside the grid (limit 1 %), 0.08 % in the last metre before the relief fades (limit 0.5 %), 0 beyond the grid. **Ground bake**: 1 698 points within 1.9 mm of the mesh surface. **Pebbles stay put**: 0 of 1 536 pebble pixels change when the camera moves 1.24 m across cell boundaries. Lifetime: presets, resizes, a second viewport, freeing the scene, a scene change during a bake. All four demo scenes render at every preset, their ground faces up, and their runtime bakes take about 0.3 s (printed by the test). The demo's fly camera flies, and C digs a crater where it looks (hills). |
| bake tests (headed, 162 checks; headless without the render comparison) | **Accuracy**: points inside the baked triangles of a 60 mm bump against the height field at the same uv: largest distance 0.47 mm at a 0.5 mm tolerance (736 triangles). **Adaptivity**: 107 times the triangle density on the bump as on the flat plane. **Vector displacement**: a plane with only a vector map (x 0.5, y -0.3, z 1 times a 50 mm bump) has its vertices within 0.001 mm of the rest position plus the map's vector in the tangent frame, points inside the triangles within 0.48 mm at a 0.5 mm tolerance; a purely sideways bump refines 32 times denser where it is and moves nothing off the plane; grey is no offset in an unsigned map; object space moves along the object's axes; a vector-displaced box stays closed; with a height map the two add up; a vector map at scale 0 bakes as before. **Closed meshes stay closed** (every edge in exactly two triangles after welding): a box with triplanar and with UV mapping (seams, hard edges), a UV sphere (seam, poles), a world-mapped cylinder (caps). Locked borders do not move (free ones by 22 mm); the budget caps the count exactly (3 000) and the statistics report the error left; identical results for repeated bakes and any thread count; scale 2 halves the object-space displacement (the tolerance is in world metres, the triangle count stays the same); a rotated plane moves along its own normal; a plane's 45-45-90 triangles stay 45-45-90 over 40 001 triangles; normals follow the slope, tangents along +u and perpendicular, `CUSTOM0` / `CUSTOM1` rest data, 7 LODs sharing the vertices; cancel stops a 5 M-triangle bake within milliseconds. **Sculpt**: `pick()` finds the uv under a ray; a sculpted plane's vertices rise by the sculpt map at their uvs (within 0.001 mm), refined where it changes, and on top of a material's relief the two add up; another stroke changes the bake key, the same map gives the same key, and removing the map restores the original key. **Skinned meshes**: a skinned strip bakes with its bone weights interpolated linearly between the source vertices (within 0.00001) and summing to 1, and its clusters deform with the node's skin and skeleton. **Cache**: after a second bake the first is listed as unused and the node's own only once the node is gone; `remove()` takes them away; only files named like bakes, collision shapes and sculpt maps count. **Node**: background bake with progress, the cache file the scene refers to, reuse of the cached file, Rebuild, Clear, the source untouched; staleness after a new relief depth, quality, source edit, scale, or (world mapping) position, not after moving a UV-mapped mesh; trimesh collision of its own resolution that a ray hits 0.4 mm from the relief's top, removed with collision None; a saved and reloaded scene refers to the bake and is not stale. **Render**: on the pixels where the relief shows, a baked mesh differs from the parallax render of the same material by 0.0065 (mean), the normal map applied on top of the geometry by 0.091; a baked mesh marches no parallax steps; the Tessellation view. |
| terrain tests (headed, 89 checks) | **Heights**: every vertex is the heightmap's (0.003 mm), between vertices the triangles' plane, outside nothing. **Chunk LODs**: each halves the quads (skirts included), keys increase and equal each LOD's largest height error, and every chunk's skirts hang deeper than the widest gap two LODs can leave on its border. **Layers**: rock on an 80-degree flank, snow on the peak, the first layer alone on low gentle ground; the combined layered material keeps each layer's textures, texture size and vertex-colour mask; a splat map overrides the rules. **Collision**: 200 rays hit the HeightMapShape3D within 0.02 mm of the drawn surface. **Detail field**: its ground data has texel centres on the vertices and stays within the field's lift (1.6 mm of 4.3 mm) of the drawn surface on 378 displaced points, with the dominant layer right on all. Three property changes in a frame rebuild once. **Streaming**: exactly the chunks within the radius are built, each with its collision shape, identical to the whole terrain's; heights the same streamed or not; the ground window follows the camera, and after flying across the far old chunks are gone. **Painting**: the painted layer takes over in the middle and fades at the edge, the vertex colours and the field's ground data follow, erasing, saving and clearing work, and a chunk streamed in after the paint carries it. **Editing**: `intersect_ray()` lands on the surface (60 rays, within 0.06 mm), on the ray and no farther than the point aimed at; a float heightmap of one texel per vertex is edited as it is, another becomes one with the same heights; raising 2 m gives 2.0000 m in the middle, 1.125 m at half the radius (the falloff) and nothing beyond; the chunks, the collision, the slope rule (rock on the new flank) and the field's ground data follow; a region set back restores the heights exactly; flatten, smooth; a rebuild keeps the edits; painting the splat map keeps the rules' weights elsewhere and undoes; a streamed terrain sculpts its built chunks, their collision and chunks built later. **Generate and erode**: a generated landscape spans 0..height_scale, erosion changes the heights and the chunks follow, the exported EXR is the heights at one texel per vertex. **Roads**: on the band the ground takes the line's height (within 0.0002 mm), in the falloff it lies between, beyond it is untouched, the layer is painted under it; a conforming path is half as bumpy as the ground under it and the terrain follows it. **Native passes**: the native chunk builder makes the GDScript one's chunks (a whole terrain, a streamed one with the rules, a splat map with occluders: identical to 0.0000001), and the native grid passes its heights, weights, ground data texels and ground data error. **Render**: the terrain draws from above and is culled from below (front faces wind right); the engine draws 14 times fewer primitives far away (its mesh LOD picks the coarser index LODs). |
| Compatibility and Mobile renderers (`tests/renderer_tests.gd`, 6 checks each) | All 30 surface variants compile and draw; a box 0.5 m in front of a depth-writing wall shows (the depth lands in the renderer's depth range: OpenGL's clip depth is -1..1); a deformation mark changes the floor's picture under it (luminance by 0.39) and nothing beside it; the five demo scenes draw at Low and Ultra; the gravel path's field captures its ground on Mobile, and on Compatibility stays off instead of drawing a flat sheet. Shader compile errors fail the suite through the log scan. |
| demo / editor smoke | The demo and the editor with the demo open run without script errors, engine errors or leaks. |
| standalone addon (shipped archive) | Builds the `git archive` users download (`.gitattributes` export rules applied), checks it holds only `LICENSE` and `addons/gads` with no Markdown link to a file it does not ship, puts it alone into a fresh project, lets the plugin register its globals and checks that a POM ground and a GADSDisplacementField3D with pebbles render there. |
| editor plugin actions | In a real editor: Create Material from Selected Textures (a DirectX set into a triplanar material with its converted height, packed ORM and flipped normal map), Add GADSManager Node, Add GADSDisplacementField3D, Convert Materials (a mesh and a CSG shape), Bake Ground, Make Selected Meshes GADSMeshInstance3D and Bake Selected GADSMeshInstance3D (the bake saved into `res://gads_baked/`), each with undo and redo; the inspector's Bake / Rebuild / Clear buttons; a Sculpt stroke sent as the viewport sends it (the sculpt map saved next to the bakes, baked again, undo and redo); Clean Bake Cache (a stale bake listed and removed, the bake in use and other files kept); the terrain's Sculpt and Paint strokes, Generate and a road's Apply to Terrain (the edited maps saved into the data directory and referred to by the saved scene, undo of the first stroke gives the original map back, redo); a second bake that replaces the first while it is in use; Validate Setup; Prepare Height Maps; a save that writes no internal nodes, keeps the materials' saved variant and the field's properties (the node's preset does not touch them in the editor) and refers to the bake files instead of embedding them. |
| offline Blender bake (`tests/test_blender_bake.py`) | Vertex-exact displacement against the height map for the primitives and mappings, decimation and glTF export. |
| mutation checks (`tests/run_mutations.py`) | Re-introduces one bug at a time and expects its tests to fail: height map without mipmaps, march at mip 0, wrong parallax sign, no binary refinement, world-planar rotation sign, triplanar X plane mirrored, zero-weight planes marched, no distance fade, `LIGHT_VERTEX` not written, self-shadow ray reversed, Lambert instead of Burley in `light()`, a clamped GGX term, no energy compensation, depth written by every POM variant, depth not rounded, no geomorph at ring seams, no grid snapping, vertex fetch at mip 0, relief pushed down, pebbles seeded by window slot, a bake that ignores the layers, a feature switch that adds features, an inverted remap that flattens, the field's parallax sign, the field's self-shadow direction, the field's relief measured from ground + lift, kerbs not marked (shader and CPU), ground beyond the bake displaced, local lights that never or always self-shadow, field parameters set when unchanged, a scatter that stops following its field, presets that miss CSG shapes, Custom settings not followed, the demo camera's script attached after it is ready, a baked mesh that still marches, a baked mesh lit by the full normal map on top of its slope, a bake key that ignores scale and rotation, the bake cache ignored, a collision body saved with the scene, the detail layer outside the slab, layers blended without heights, a slope band ignored, a runtime tessellation that never refreshes, world-planar parallax that
ignores deformation, terrain skirts too shallow, the terrain's ground data off its vertices, the
Vulkan depth range on OpenGL. Each prints what the failing tests measured. On the GTX 1080 the first 29 were all caught; on Mesa's lavapipe 35 of the 36 are, all but "depth not rounded": there the depth pre-pass and the colour pass agree without the rounding, so the bug it guards against does not occur. The mutations added in 0.2 (baked meshes, detail and layered materials) are all caught on lavapipe. |

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
- **Baked displacement** is a bake in the rest pose: skinned meshes keep their bone weights, but
  blend shapes are dropped, and a mesh moved at runtime keeps its bake (a world-planar or triplanar bake then
  no longer matches the world-space texture; UV-mapped bakes move freely) until a runtime
  tessellation (`view_dependent`) replaces it. A runtime tessellation takes a worker thread for
  tens to hundreds of milliseconds; the old mesh shows meanwhile. The native
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
- **On Compatibility the ground cannot be captured** (the renderer's approximate sRGB round trip
  breaks the 16-bit height code): a field there needs a bake saved from the editor, else it stays
  off and the ground keeps its parallax.
- **The ground bake** is a static height field: moving ground or ground edited at runtime needs
  a new bake (`bake_ground()`, a few frames: 0.2-0.3 s for the demo's 90 x 90 m at 5 cm texels, as
  printed by `tests/field_tests.gd`; the field is hidden meanwhile). Texels at the bake's edge
  and next to no ground are not displaced. A bake takes 8 bytes per texel (26 MB for that
  ground) in memory and on the GPU.
- **Relief within one material only.** Each ground layer is displaced by its own height map and
  blended by the bake's weights; there is no height-based blending between layers.
- **Height map precision.** 8-bit heights terrace. The Poly Haven EXRs used by the demo are
  float; other sources may not be.
- On the **Mobile** and **Compatibility** renderers the presets' costs are not measured (they
  were made for Forward+); start at Low on mobile hardware. XR is untested.

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
- Cluster streaming and GPU-driven culling of clusters (a step towards virtual geometry),
  streaming bakes, blend shapes in bakes, macOS and ARM builds of the native library.
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
