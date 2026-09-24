# Research notes: displacement for Godot 4.7.2

These are the research notes written before the implementation (2026-09-23; section A of a
wider study that also covered a post-effects addon and one game's settings, left out here).
Engine claims were checked against the Godot 4.7.2-stable source. Where the implementation
ended up different, [ARCHITECTURE.md](ARCHITECTURE.md) is authoritative; the main differences:

- **The near-camera geometry does not replace parallax mapping.** The notes planned parallax
  only in the grid's outer fade band. A 2 cm grid cannot carry 2-3 cm gravel stones (measured:
  the stones went soft and flat), so every grid fragment still marches the full-resolution
  relief along its true view ray; the geometry adds coverage, silhouettes, real depth and the
  coarse relief.
- **No constant offset at the grid's edge.** The ground materials under a field use
  `height_center = 0` (relief above the surface, UE's "Center 0"), the grid's convention too, so
  grid and parallax agree exactly where the grid fades out (measured within 1 %).
- **The opt-in depth write rounds its depth** to 12 mantissa bits: the depth pre-pass and colour
  pass are separately compiled and disagreed in the last bit on 1.3 % of pixels, which the
  EQUAL depth test turns into holes.
- **Every variant declares `render_mode diffuse_burley`**: a spatial shader without render modes
  gets Lambert, while BaseMaterial3D and the addon's `light()` use Burley.
- **Crack-free seams** come from geomorphing with forced edge vertices; no skirts are needed.
- Measured costs replace the estimates below; see the README.

## A. Displacement addon

### A1. What Godot 4.7.2 can and cannot do

- **Material shaders have three stages only**: `vertex`, `fragment` and `light`.
  - `SRC\servers\rendering\shader_types.cpp:91-234` declares them.
  - `scene_shader_forward_clustered.cpp:96-98` maps them to the vertex and fragment GPU stages.
  - There is no hull, domain or geometry stage.
- **RenderingDevice has tessellation stages, but material shaders cannot use them.**
  - `rendering_device_commons.h:592-604` and `rendering_device.cpp:9739-9751` define them.
  - Calinou (maintainer), 2025-10-18: the stages are exposed through RenderingServer/RenderingDevice "but they aren't available in the Godot shader language" (godot-proposals#5995).
  - The tessellation proposal #5995 and the virtualized-geometry proposal #2793 are both still **open**.
  - The mesh-shader pull request godot#88934 is **open, not merged**, and the 4.7.2 Vulkan driver has no mesh-shader code.
- **A CompositorEffect can draw geometry into colour and depth, but that is a second renderer.**
  - The geometry would get none of Godot's lights, shadow casting, GI, fog or motion vectors.
  - It would also be absent from the depth prepass and the normal-roughness buffer, so SSAO and SSR would not see it.
  - Verdict: rejected.
- **Things that *are* available and matter here:**
  - **`LIGHT_VERTEX`** (since 4.3, godot#91136) is a writable copy of the fragment position. The engine substitutes it for `vertex` after the user fragment code, so shadow lookups and light attenuation use the displaced point (`SRC\...\scene_forward_clustered.glsl:1321,1367`; `spatial_shader.rst:419`). It moves only where light and shadow are *received*; it does not change depth or shadow casting.
  - **`DEPTH`** is a custom depth write. Its cost:
    - It becomes `gl_FragDepth` with no conservative-depth qualifier (`scene_shader_forward_clustered.cpp:774`), so early-Z and hierarchical-Z are lost for that material.
    - The depth prepass runs the whole user fragment code (`scene_forward_clustered.glsl:1351`), so the POM march runs **twice**.
    - The colour pass then tests with `COMPARE_OP_EQUAL` (`scene_shader_forward_clustered.cpp:452-457`).
    - Shadows still come from the flat surface. Writing `DEPTH` does not stop the shared default shadow material being used (`scene_shader_forward_clustered.h:298-300`), and PR #90881, which would have changed that, was closed without merging.
  - **Custom `light()`** can read varyings written in `fragment()` (`shading_language.rst` "Varyings"). It **replaces** the built-in BRDF for direct light (`spatial_shader.rst:545`), so self-shadowing through `light()` means re-implementing Godot's Burley plus Schlick-GGX. `LIGHT_IS_DIRECTIONAL` and `LIGHT_IS_AREA` exist in 4.7 (`shader_types.cpp:219-220`); area lights must be handled too.
  - **Vertex displacement runs in every shadow pass.** Writing `VERTEX` disables the shared shadow material (`scene_shader_forward_clustered.h:298-300`), and the material's own depth variant runs the user vertex code (`render_forward_clustered.cpp:461-463, 4782-4807`). `IN_SHADOW_PASS` is available to reduce the work there (`shader_types.cpp:83`).
  - **Godot's built-in "Deep Parallax"** (BaseMaterial3D) is linear steps plus **one** secant interpolation, with no depth write, no shadows and a maximum of 64 layers; the defaults are 8 minimum and 32 maximum (`scene/resources/material.cpp:1524, 1554-1559, 1145-1146, 3967-3968` @4.7.2-stable).
  - **`Image.FORMAT_R16`** (value 39) exists in 4.7, so a 16-bit height map is possible (`SRC\doc\classes\Image.xml:782`). However, **the PNG loader converts 16-bit to 8-bit** (`drivers/png/png_driver_common.cpp:76-79` @4.7.2-stable), and **EXR** (half or float) is the only 16-bit file route.

### A2. What UE5 actually does (reference only)

- **Nanite Tessellation**, experimental since 5.3 and "shipped in 5.4" according to Brian Karis (graphicrants, 2026-02):
  - A material with *Enable Tessellation* and a **Displacement** pin (0-1).
  - **Magnitude** is the height range in world units; **Center** is the value that means no change (0.5 = both directions, 0 = outward only).
  - **Displacement Fade** takes a start and an end size in pixels.
  - Enabled with `r.Nanite.AllowTessellation=1` and `r.Nanite.Tessellation=1`. Nanite meshes only; landscape needs about 64 times smaller magnitudes.
  - Patches are diced to about 1-2 px triangles and go through the **software** rasterizer only. Epic warns that a large Magnitude "seriously" hurts performance, especially with virtual shadow maps.
  - Docs: dev.epicgames.com "Nanite Virtualized Geometry" and "Working with Nanite-Enabled Content".
- **PCG runtime generation** spawns and culls small scattered content around generation sources, on hierarchical grids with a GPU path. This is the "micro scatter" that makes gravel read as loose stones.
- Take-away: UE5 gets real silhouettes at about 1-2 px dicing *everywhere*. We can get about 7-24 px dicing *near the camera, on horizontal ground*, and POM elsewhere.

### A3. Techniques: verdict, design, estimated cost

#### A3.1 Parallax occlusion mapping done well (all presets)

This is the specification for `sd_core.gdshaderinc`.

1. **Mappings.**
   - UV (tangent space, needs tangents).
   - World-planar XZ with rotation and offset (ground; no UVs needed; lets street paving line up with a street).
   - Triplanar.
2. **Height in metres, not in UV units.** Store `height_m` (relief depth) and `tile_m` (real tile size; Poly Haven publishes both through `api.polyhaven.com/info/<id>` `dimensions`, for example gravel_stones is 2000 x 2000 mm). Add a `remap_min/max` pair taken from the map's 1st and 99th percentiles; the importer tool computes it (§A4).
3. **Distance and LOD fade.**
   - `fade = 1 - smoothstep(fade_start, fade_end, view_distance)`.
   - Skip the march entirely when `fade == 0` or when the height mip level is 5 or higher. The branch is coherent across screen regions, so it is cheap.
   - The step count scales with `fade`.
4. **Adaptive linear search:** `n = mix(max_steps, min_steps, |N·V|) * fade`, as Godot does, but with…
5. **Mip-correct sampling inside the loop.** Take `dFdx/dFdy` of the base UV *before* the loop and use `textureLod` with a precomputed LOD (or `textureGrad`). Implicit-derivative `texture()` inside a data-dependent loop is undefined in GLSL and forces the full-resolution mip at distance.
6. **Refinement:** one secant step followed by 3-4 binary steps (relief mapping, Policarpo 2005). That is more robust than a single secant step on high-frequency gravel.
7. **`LIGHT_VERTEX = VERTEX + view_dir * t`**, where `t` is the march depth in metres. Shadows from other casters and light falloff then land on the relief, not on the flat plane. It costs one multiply-add and should be on at every preset.
8. **Self-shadowing** (Medium and up, main directional light only).
   - In `light()`, when `LIGHT_IS_DIRECTIONAL` and within `self_shadow_distance`, march 6-12 steps from the displaced point towards the light in height space.
   - High uses the **contact-hardening** soft term from Tatarchuk 2006: occlusion is the maximum over steps of `(h_sample - h_ray) * k / step_distance`.
   - The fragment-to-`light()` varyings carry the parallaxed UV, the tangent frame and `t`.
   - Cost of choosing this route: `light()` must re-implement Burley diffuse plus Schlick-GGX specular (and area lights). A render test must hold it within about 1-2 % per pixel of StandardMaterial3D when self-shadowing is off. This is the same kind of test Hybrid GI uses for its converted materials.
9. **Optional `DEPTH` write ("pixel depth offset")**, per material and opt-in only, never part of a preset.
   - It makes props and decals intersect the relief correctly.
   - Estimated cost: about 2-3.5 ms if the material fills the screen (a second march in the prepass plus lost early-Z), against about 1-1.5 ms without it.
   - Use it on walls where a prop is pressed against bricks, not on large ground areas. The near-field grid (A3.2) gives real depth where it matters most.
10. **Silhouette clipping** (discard when the offset UV leaves 0-1) applies only to bounded UV-mapped quads such as kerb tops and stair noses. It is off by default and has no value on tiled ground.
11. **Triplanar:** march only the planes with weight above 0.05 (renormalized), and at most two of them. Flat ground then pays for one march, not three.

**Estimated cost** (GTX 1080 at 1080p, POM surface over the whole screen; the displacement research agent's estimate from 277 GTexel/s peak and 25-40 % efficiency for dependent, divergent loops):
- 32 steps + 5 refinement + 8 shadow steps: about 0.9-1.4 ms colour pass.
- Low, at about 12 steps with fade: about 0.3-0.5 ms.
- With `DEPTH`: about 2-3.5 ms.
- Ground usually covers about 50-60 % of an FPS frame, so scale these by that share.

#### A3.2 Review of an existing game's triplanar POM shader

The starting point was a triplanar POM shader from an existing Godot 4 game (a concrete floor and wall material). It works and is readable. These findings should be fixed in the generalized addon shader, and such materials should then move to it.

| # | Finding | Effect | Fix |
|---|---|---|---|
| 1 | **Every texture of both POM materials is imported without mipmaps.** All 9 `.import` files have `mipmaps/generate=false`, `compress/mode=0`. | Aliasing and shimmer at distance. Every one of the 12-40 loop samples reads the 2K level-0 texture (cache thrash, which is the worst case for POM bandwidth). Uncompressed 2K textures use about 12-16 MB of VRAM each. | Mipmaps on. Height: lossless (or R16/RH `.res`) with mips. Albedo/normal/roughness: VRAM compressed (BC7/BC5). |
| 2 | **Probable sign error on the floor plane:** `uv_y = tp.xz` = (x, z), but the march direction is `vec2(vdir.x, -vdir.z)`. The derivation for the X and Z planes checks out; for the Y plane it gives `(vdir.x, +vdir.z)`. | On floors the relief is displaced the wrong way along world Z, which makes the texture swim when you look along ±Z. | Flip it, and prove it with a render test against real geometry (the POM-vs-mesh test in A7). *Not reproduced yet; it is derived from the code.* |
| 3 | **All three planes always march, even at zero weight.** On a flat floor `weights = (0,1,0)`, but the X and Z planes still run up to `max_layers` = 40 steps. | Roughly 2-3 times the necessary cost on floors and walls. | Skip planes with weight below 0.05. |
| 4 | `texture()` inside a data-dependent loop. | Derivatives are undefined in non-uniform control flow; combined with #1 it gives the wrong mip. | `textureLod`/`textureGrad` from the pre-loop derivatives. |
| 5 | **`height_scale` is in UV units:** 0.055 / `uv_scale` 0.35 = **about 16 cm** of relief on the concrete floor. | The relief depth depends on the tile size. 16 cm is far more than damaged concrete (about 1-3 cm), and exaggerated depth is what causes the "sliding texture" look. | Specify height in metres. |
| 6 | No distance fade. | Full march cost on sub-pixel detail at 60 m. | Fade by distance or mip level. |
| 7 | No `LIGHT_VERTEX`, no self-shadowing, no refinement beyond one secant step, no `DEPTH`. | Flat-looking lighting on the relief. | A3.1 items 6-9. |
| 8 | The grime pass samples height three more times. | Minor. | Reuse the march's final heights. |
| 9 | The comment says a low tier "can do [this] at runtime", but nothing drives it. | POM is always on, and the settings cannot turn it off. | Addon quality preset (§C). |

#### A3.3 Real geometry near the camera: `DisplacementField3D` (High and Epic)

- **What it is.** A camera-centred **geometry clipmap** (Losasso & Hoppe 2004), with **CDLOD-style geomorphing** between levels (Strugar 2009) so that no skirts or crack fixes are needed.
  - The mesh is L nested levels of N×N quads. Level k has spacing `s0*2^k`, and the grid snaps to 2 × the level spacing so vertices never swim.
  - At 1080p and 90° FOV, 1 px on the ground at distance d is about d/960 m. With level spacing doubling, the on-screen quad size stays inside a factor-2 band, and N sets that band. Estimate:
    - **High** = 4 levels, N=160, s0 = 2 cm, reach about 13 m: about 80k quads (160k triangles), about 12-24 px per quad.
    - **Epic** = 4 levels, N=256, s0 = 1.5 cm, reach about 15 m: about 210k quads (420k triangles), about 7-15 px per quad.
  - Keep triangles at least about 4 px, because sub-4 px triangles waste 2×2 pixel quads (Calinou in #5995).
- **Vertex height.** `y = base(x,z) + lift + amp(x,z) · fade(d) · remap(h(x,z))`.
  - `h` is sampled with `textureLod` at the mip that matches the vertex spacing, which avoids vertex sparkle.
  - `amp` and the layer come from a mask. The texture sets are a `Texture2DArray` of up to 4 layers, in the same world-planar mapping as the ground material.
- **Convention: relief goes "up only", plus a lift of 1-2 mm.** The original ground mesh **stays**, and the grid lies on top of it.
  - No `discard` is needed, so early-Z is kept.
  - Under the grid, the ground's fragments fail the prepass `EQUAL` test, so its POM is never shaded there.
  - Where the mask says "not displaceable" (for example a concrete kerb next to the gravel), the vertices are pushed **below** the base surface, so the real ground hides them. The boundary follows the mask at vertex resolution, with no discard.
  - (The displacement research agent found that stencil is not an alternative: materials that read stencil are moved to the alpha pass, `render_forward_clustered.cpp:4211-4218`.)
- **Seam to POM.** In the outer band, the grid's amplitude fades to 0 while the *grid material's* POM strength fades in (`pom = amp·(1-fade)`). Beyond the grid, the ground material's own POM carries on.
  - The remaining mismatch: POM relief sits below the surface and the grid's relief sits above it. That is a constant offset equal to the amplitude (2-5 cm), at 10-15 m, inside a fade band.
- **Base height source.**
  - *Heightfield terrain* (a terrain with its own height grid): sample that grid directly. This is exact and cheap.
  - *Arbitrary ground meshes* (a sculpted floor, city streets made of imported meshes): a **one-time bake**. Render only the meshes on a "displaceable ground" render layer into a top-down orthographic SubViewport in a *separate World3D*, with a capture material that writes world height and layer ID.
    - The result is an RF height texture plus an R8 ID texture, for example 0.1 m texels: 2048² for a 200 m map is about 16 MB + 4 MB.
    - Save it as a resource from an editor tool; the runtime fallback bakes at load.
    - Prior art: Terrain3D bakes its displacement atlas with a viewport; forum and blog examples use orthographic depth captures to fit grass and snow.
  - Only nodes on the displaceable layer are captured, so tunnel roofs and overhangs are excluded.
- **Normals.** Base normal (central differences of the base height) combined with a whiteout blend of the texture's normal map. The per-stone shading below 1 cm stays in the normal map.
- **Shadows.** `cast_shadow` is **off** by default.
  - Otherwise 2-4 cascades would re-run the vertex shader (A1).
  - A 4096 cascade over 5-50 m cannot resolve 3 cm stones anyway.
  - The grid material uses the same heightfield self-shadow term as POM (A3.1 item 8), so stone shadows are crisp regardless of the shadow-map resolution.
  - It still *receives* shadow-map shadows, and it is in the depth and normal prepass, so **SSAO acts on real crevices**.
- **Collision** stays on the original mesh. Feet may sink by up to the amplitude (2-5 cm). UE's Nanite displacement behaves the same way.
- **Estimated cost:**
  - High: about 150k triangles × 2 passes (prepass + colour), no shadow pass, about 0.2-0.4 ms geometry. The grid's fragment shading replaces the POM ground shading it covers, so the net fragment cost is about zero.
  - Epic: about 0.5-1.0 ms.
- **Scope limits.**
  - Height-field-like ground only: no overhangs and no vertical walls.
  - The grid uses world-planar mapping, so the original mesh's UV layout is **not** kept. Paving patterns need a per-area rotation and offset, and streets imported as UV-mapped GLB meshes need their road and sidewalk materials replaced by world-planar ones.
  - One field per rendering camera.
  - It must not be put over Terrain3D terrain. Terrain3D (MIT) already displaces its own clipmap: PR #747, subdivision levels 0-6 and a displacement atlas; about 15-45 % cost according to 80.lv, a secondary source. For Terrain3D users, the addon should document "use Terrain3D's displacement" and provide only POM for meshes.

#### A3.4 Micro-scatter: `PebbleScatter3D` (Epic, optional)

- **GPU particle cells that snap to the camera.** The pattern is from Terrain3D's `extras/particle_example`, which is MIT.
  - A 7×7 grid of 2 m cells, each a `GPUParticles3D`.
  - A process shader places pebbles by `(cell, index)` hash on the same base height + displacement, with density from the layer mask. Pebbles are biased toward height-map valleys, where loose stones settle.
  - No CPU sampling and no per-frame MultiMesh rebuild.
- **Meshes:** 4-6 procedural pebbles (noise-displaced icospheres, 40-80 triangles, generated at load; no asset licence issue), triplanar rock material, no shadows, dithered visibility-range fade.
- **Estimated cost:** 5-8k instances within about 10 m, about 0.4M triangles × 2 passes: about 0.3-0.6 ms.
- **Value:** high for gravel and rubble, because it breaks the "painted on" read at grazing angles. None for cobblestones.
- **ProtonScatter** (MIT, v4.2.0) is static placement with chunks and has no camera-following mode. It is kept for authored scatter, not used for this.

#### A3.5 Offline "hero" subdivision + displacement (Blender headless; optional tool, v0.2)

- **What the tool does.** It lives in the repository at `tools/bake_displaced_mesh.py` (run with `blender -b -P`) and is **not** part of the addon folder or the Asset Store zip.
  - Import the GLB.
  - Subdivide to a target edge length.
  - Apply a Displace modifier with the height map, midlevel and metres.
  - Decimate to a triangle budget.
  - Export a GLB. Godot's import-time LODs (meshoptimizer) handle distance.
- **Value:** real silhouettes and real *cast* shadows on the few props where POM visibly fails: brick wall caps, a cobble kerb module, rubble piles, stair noses.
- **Cost:** triangles and VRAM. A 2×2 m cobble patch at 1 cm is 80k triangles before decimation.
- **Not suitable for** large ground areas: at 200 m² and 1 cm resolution it would be millions of triangles.
- **Verdict:** worth doing for about 5-20 hero assets, after the runtime part ships.

### A4. Textures available on this machine

- **`D:\game-assets\polyhaven-textures`**: 862 sets, all CC0 (`<name>.license.json`), each with 2K JPGs (diff, nor_gl, rough, arm, ao, disp).
  - **859 have a displacement map.** The three without one are `fabric_pattern_05`, `fabric_pattern_07` and `fine_grained_wood`, none of them relevant.
- **Precision.**
  - Every local height map is 8-bit JPG, and JPEG block artefacts show under self-shadowing and at grazing angles.
  - Godot 4.7 loads 16-bit PNG as 8-bit (A1).
  - For the demo's key surfaces, download **EXR displacement** from `https://api.polyhaven.com/files/<id>` (`Displacement` → `2k` → `exr`/`png`, also 1k-16k available), then import it lossless as RH, or convert to an `Image.FORMAT_R16` `.res`.
- **Relief statistics (measured).** The script computed per-map 1st/99th percentiles and a high-frequency share (std of map minus 128² blur, divided by range; high means stone-scale relief, low means macro undulation).
  - Computed by a one-off analysis script (not kept in the repository).
  - The addon's importer should compute the same p1/p99 and store them as the remap range.

| Use | Recommended sets (tile size m · p1-p99 range · hf) | Notes |
|---|---|---|
| **Gravel path, "individual stones"** (the demo's hero surface) | **gravel_stones** (2.0 · 0.42 · 0.13), **rocky_gravel** (1.81 · 0.40 · 0.12), **clean_pebbles** (2.0 · 0.55 · 0.13), gravel (2.0 · 0.35 · 0.17), gravel_floor_03 (2.5 · 0.35 · 0.19) | Clear stone separation. `bicolour_gravel` has only **0.15** range: fine aggregate, almost flat relief, good for POM only. Avoid `gravel_floor_04` (mostly dust), `pebbles` (0.14) and `river_small_rocks` (0.19). |
| Larger pebbles and river stones | ganges_river_pebbles (2.16 · 0.64), dry_river_pebbles (2.0 · 0.63), large_pebbles (2.0 · 0.65) | Big, rounded; strong displacement candidates. |
| **Cobblestone** (old-town streets, demo) | **cobblestone_floor_08** (2.0 · 0.80), cobblestone_floor_03 (2.4 · 0.80), cobblestone_floor_07 (2.0 · 0.75), cobblestone_floor_13 (2.0 · 0.84), cobblestone_01 (2.4 · 0.76), cobblestone_large_01 (4.0 · 0.64); rectangular setts: square_cobblestone (2.0 · 0.35), cobblestone_square (1.0 · 0.47) | High range, low hf: large rounded setts. They need world-planar rotation to follow the street. Generated texture sets often come with **no height map**: nothing to displace. |
| Sidewalk and pavers | pavement_01 (1.5 · 0.67), pavement_04 (3.1 · 0.71, brick), concrete_pavers (1.92 · 0.44), herringbone_pavement (2.0 · 0.41) | |
| Rocky ground | rocks_ground_02/04/05/06 (2-3 · 0.75-0.86), rock_path (2.0 · 0.54), brown_mud_rocks_01 (0.53), stony_dirt_path (2.17 · 0.32) | rocks_ground_* are large rocks, with hf about 0.01: grid displacement shows them best. |
| Rubble | rubble (2.0 · 0.45), concrete_debris (2.0 · 0.47), broken_brick_wall (1.8 · 0.57), castle_brick_broken_06 (2.5 · 0.55) | |
| Brick walls (POM + self-shadow; hero bake candidates) | brick_wall_001 (3.0 · 0.59), brick_wall_10 (1.9 · 0.55), medieval_red_brick (2.0 · 0.55), brick_wall_04 (0.51) | Avoid red_brick (0.25), red_bricks_04 (0.15) and mixed_brick_wall (0.16). |
| Avoid for displacement | embedded_rock_floor (0.07), floor_pavement (0.07), damaged_concrete_floor (0.12: so little relief that a POM floor made from it needs an exaggerated height scale, as in A3.2) | |

- Nothing is missing for the demo. The only reason to download is **16-bit EXR** height for the chosen sets.
- Backup CC0 source: ambientCG (Gravel0xx, PavingStones0xx, Rocks0xx), with 16-bit PNG displacement. It needs EXR conversion for Godot, because of the 8-bit PNG loader.
- Check each set visually before use; the statistics rank the candidates, they do not choose for you.

### A5. Architecture (planned)

```
addons/surface_displacement/
  plugin.cfg, plugin.gd          global shader uniforms (sd_ground_height, sd_ground_mask, sd_field_params),
                                 Tools menu: Add node, Convert materials, Bake ground, Analyse height map
  nodes/surface_displacement.gd  SurfaceDisplacement manager node: preset, applies quality to every
                                 material in group "surface_displacement", owns field + scatter, timings
  nodes/displacement_field_3d.gd clipmap grid (mesh built in code), camera follow + snapping
  nodes/pebble_scatter_3d.gd     camera-snapped GPUParticles3D cells
  core/sd_settings.gd            preset Resource (Low/Medium/High/Epic/Custom)
  core/sd_layer.gd               texture set: albedo/normal/ORM/height, height_m, tile_m, remap p1/p99, rotation
  core/ground_bake.gd            top-down capture -> height/ID textures (+ direct heightfield path)
  shaders/sd_core.gdshaderinc    POM march, refine, LIGHT_VERTEX, self-shadow, Godot-matching BRDF light()
  shaders/sd_uv.gdshader, sd_world.gdshader (planar/triplanar), sd_field.gdshader, sd_pebble.gdshader
  shaders/variants/*.gdshader    #define-generated variants (self-shadow, depth-write) -> precompiled at load
  tools/material_converter.gd    StandardMaterial3D (+heightmap) -> SD material, undoable
  tools/height_analyser.gd       p1/p99, suggested height_m, EXR -> FORMAT_R16 .res
demo/  gravel path, cobble street + sidewalk, brick wall, rubble; fly/orbit camera; bench camera path
tests/ logic (headless), render (headed), benchmark (1080p budgets), mutations, shipped archive, editor check
tools/ godot.py runner, capture_screenshots, reference mesh builder, bake_displaced_mesh.py (Blender, not shipped)
docs/  ARCHITECTURE.md, RESEARCH.md (this file, trimmed), images/
```

- **Quality switch at runtime.** Changing a preset swaps the Shader of each registered ShaderMaterial to the matching variant and sets uniforms. All variants are compiled once at load by drawing each one for a frame off-screen, which avoids pipeline hitches. Godot 4.4+ ubershaders reduce hitches but do not remove them for new variants.

### A6. Presets and budgets (targets to measure)

Measurement convention, as in Hybrid GI: time added against the same scene with flat normal-mapped StandardMaterial3D ground, at 1080p, GTX 1080, V-Sync off, 300 frames after warm-up, with the ground covering about 60 % of the screen.

| Preset | POM | Self-shadow (sun) | Near-field grid | Scatter | Budget (est.) |
|---|---|---|---|---|---|
| Off | none (normal map only) | - | - | - | 0 |
| Low | 6-16 steps + 2 secant, fade 12→20 m, LIGHT_VERTEX | off | off | off | **0.5 ms** |
| Medium | 8-24 + 1 secant + 3 binary, fade 20→35 m | hard, 8 steps, ≤ 20 m | off | off | **1.2 ms** |
| High | as Medium | contact-hardening, 12 steps | 4 lv × 160², 2 cm, about 13 m | off | **2.0 ms** |
| Epic | 12-32 + refine, fade 30→50 m | contact-hardening, 16 steps | 4 lv × 256², 1.5 cm, about 15 m | ≤ 8k pebbles, 10 m | **3.0 ms** |

- **Settings exposed** (node properties and a `SDSettings` resource): `enabled`, `preset`, `pom_enabled`, `pom_min/max_steps`, `pom_fade_start/end`, `self_shadow` (off/hard/soft), `self_shadow_distance`, `near_field` (on/off), `near_field_radius`, `near_field_density` (N), `scatter` (on/off, density), and per material: `depth_offset` (opt-in) and `height_m`.
- **Debug views:** height, march steps (heat map), LOD levels, field mask, self-shadow only.
- **Timings:** RenderingDevice timestamps are not available for material cost, so measure frame-time deltas instead, as the Hybrid GI "Added" column does.

### A7. Tests (analogous to Hybrid GI's accuracy suite)

- **POM against real geometry.** The same height field is rendered as (a) a dense reference mesh built offline at 1 mm, which is the ground truth, and (b) POM.
  - Per-pixel luminance and position error below a threshold at 3 view angles × 3 planes.
  - This catches the Y-plane sign error (mutation "flip plane sign").
- **Grid against reference mesh:** silhouette overlap above 0.95. **No cracks:** a bright grid over a black background, zero holes.
- **Temporal stability:** slow camera pan, per-pixel flicker metric below threshold. This catches missing snapping or geomorphing (mutations).
- **BRDF parity:** SD material with self-shadow off against StandardMaterial3D, at most 2 % per pixel with sun + omni + spot + area lights.
- **`LIGHT_VERTEX`:** the shadow edge of a caster moves on the relief as predicted.
- **Fade seam:** no luminance step above 2 % across the grid-to-POM band.
- **Mutations:**
  - plane sign flipped
  - no refinement
  - implicit-derivative sampling
  - no distance fade
  - `LIGHT_VERTEX` not written
  - no grid snapping
  - no geomorph
  - relief pushed down instead of up (the ground occludes the grid)
  - wrong mip in the vertex fetch (sparkle test)
- **Benchmark:** per preset against the budgets. **Shipped-archive check:** only `LICENSE` + `addons/surface_displacement`.

### A8. Limitations to state in the README

- **It is not Nanite.**
  - No displacement silhouettes on walls or props, except through the offline bake.
  - POM relief casts no shadows onto *other* objects; it only receives them (`LIGHT_VERTEX`) and shadows itself.
  - Dicing is about 7-24 px, not 1-2 px, and only within about 15 m.
- **Near-field grid:**
  - Height-field ground only, with world-planar mapping.
  - It does not follow the original UVs.
  - Collision is flat.
  - Multiple viewports each need their own field.
- **POM** stretches at grazing angles. `DEPTH` is expensive and belongs on individual materials only.
- **Custom `light()`** means the addon's shaders must track Godot's BRDF across versions. The parity test guards this.

---

## F. Sources

- Local engine source (4.7.2-stable): `SRC\servers\rendering\shader_types.cpp`, `renderer_rd\forward_clustered\scene_shader_forward_clustered.{cpp,h}`, `render_forward_clustered.cpp`, `shaders\forward_clustered\scene_forward_clustered.glsl`, `renderer_scene_render_rd.cpp`, `renderer_viewport.cpp`, `storage_rd\render_scene_data_rd.{h,cpp}`, `render_scene_buffers_rd.cpp`, `shaders\effects\{luminance_reduce,tonemap}.glsl`, `doc\classes\{Environment,CameraAttributes*,CompositorEffect,RenderSceneBuffersRD,RenderSceneData,Viewport,Image,BaseMaterial3D}.xml`
- Godot on GitHub @4.7.2-stable: `scene/resources/material.cpp`, `drivers/png/png_driver_common.cpp`, `editor/import/resource_importer_shader_file.cpp`
- Godot docs (offline): `tutorials/shaders/shader_reference/spatial_shader.rst`, `shading_language.rst`, `tutorials/rendering/compositor.rst`, `volumetric_fog.rst`, `creating_movies.rst`
- godot-proposals #5995 (tessellation, including Calinou 2025-10-18), #2793 (virtualized geometry), #1942; godot PRs #88934 (mesh shaders, open), #90881 (closed), #91136 (LIGHT_VERTEX), #110671 (glow before tonemap), #110077, #106940 (AgX), #102330 (SMAA), #105437, #115027 (native motion blur, open)
- Epic: Nanite Virtualized Geometry; Working with Nanite-Enabled Content; Bloom; Auto Exposure; PostProcessSettings; PCG Runtime Hierarchical Generation; PCG GPU processing. Brian Karis, graphicrants.blogspot.com "Nanite Tessellation" and "Nanite REYES" (2026-02)
- Terrain3D (MIT) PR #747 and docs/displacement; Zylann godot_heightmap_plugin (MIT); HungryProton/scatter (MIT); GoldenThumbs/GD_LensFlares (MIT); sphynx-owner Godot-Motion-Blur-Addon, JFA_driven_motion_blur_addon, godot-motion-blur-addon-simplified and Easy-Compositor-Addon (MIT) with their issues; GPUOpen-Effects/FidelityFX-CAS (MIT)
- Papers:
  - Tatarchuk, "Practical Parallax Occlusion Mapping" (2006)
  - Policarpo et al., "Real-Time Relief Mapping" (2005)
  - Losasso and Hoppe, "Geometry Clipmaps" (2004)
  - Strugar, "CDLOD" (2009)
  - McGuire et al., "A Reconstruction Filter for Plausible Motion Blur" (2012)
  - Guertin et al. (2014)
  - Jimenez, "Next Generation Post Processing in Call of Duty: AW" (2014)
  - Mitchell, GPU Gems 3 ch. 13 (2007)
- Poly Haven API: `api.polyhaven.com/files/<id>`, `api.polyhaven.com/info/<id>` (formats and real dimensions); local texture statistics from a one-off analysis script
- The existing game shader reviewed in A3.2, and a sibling addon's layout (README, ARCHITECTURE, tests) as the template
