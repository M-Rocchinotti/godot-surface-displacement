#!/usr/bin/env python
"""Mutation checks: prove that the tests catch the bugs they are meant to catch.

Each mutation re-introduces one known bug (or removes one safeguard), runs the tests that should
catch it and expects them to FAIL. The files are restored afterwards, also when the run is
interrupted; mutations of an .import file re-import before and after. Render suites run headed.

    python tests/run_mutations.py              # all mutations
    python tests/run_mutations.py sign seam    # only mutations whose name contains a word

Exit code 0 = every mutation was caught, 1 = a mutation survived (or no longer applies).
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "tools" / "godot.py"
SH = "addons/gads/render/shaders/"
CORE = SH + "gads_core.gdshaderinc"
COMMON = SH + "gads_common.gdshaderinc"
MARCH = SH + "gads_march.gdshaderinc"
SURFACE = SH + "gads_surface.gdshaderinc"
FIELD_SH = SH + "gads_field.gdshaderinc"
GROUND = SH + "gads_ground.gdshaderinc"
PEBBLES = SH + "gads_pebble_process.gdshader"
FIELD = "addons/gads/terrain/gads_displacement_field_3d.gd"
MANAGER = "addons/gads/core/gads_manager.gd"
BAKE = "addons/gads/terrain/gads_ground_bake.gd"
MATERIALS = "addons/gads/materials/gads_materials.gd"
SCATTER = "addons/gads/terrain/gads_pebble_scatter_3d.gd"
DEMO = "demo/demo_main.gd"
MESH_NODE = "addons/gads/geometry/gads_mesh_instance_3d.gd"
MESH_BAKER = "addons/gads/geometry/gads_mesh_baker.gd"
HEIGHT_IMPORT = "demo/textures/clean_pebbles/clean_pebbles_height.exr.import"
TERRAIN = "addons/gads/terrain/gads_terrain_3d.gd"
SCULPT = "addons/gads/geometry/gads_sculpt.gd"

# (name, what it breaks, [(file, old, new)], [(suite, name filter)]); suite is "logic",
# "render" (tests/render_tests.gd), "field" (tests/field_tests.gd), "bake" (tests/bake_tests.gd),
# "terrain" (tests/terrain_tests.gd) or "compat" (tests/renderer_tests.gd on Compatibility).
MUTATIONS = [
    ("no mipmaps", "the demo height map imported without mipmaps (the crater's POM bug)",
     [(HEIGHT_IMPORT, "mipmaps/generate=true", "mipmaps/generate=false")],
     [("logic", ""), ("render", "shimmer")]),
    ("march reads mip 0", "the march samples the full-size height map at every distance",
     [(CORE, "	return 0.5 * log2(max(rho2, 1e-12)) + gads_pom_range.z;", "	return 0.0 * rho2;")],
     [("render", "shimmer")]),
    ("wrong parallax sign", "the view ray walks the relief the wrong way (the crater floor's suspected bug)",
     [(CORE, "	return vec2(dot(p.gu, v), dot(p.gv, v)) * (dot(n, p.axis) / nv);", "	return -vec2(dot(p.gu, v), dot(p.gv, v)) * (dot(n, p.axis) / nv);")],
     [("render", "pom_matches,swim")]),
    ("no binary refinement", "the linear search is followed by the secant step only",
     [(MARCH, "		if (j >= refine) {", "		if (j >= 0) {")],
     [("render", "pom_matches")]),
    ("world rotation sign", "world-planar u gradient rotated the wrong way",
     [(CORE, "	p.gu = vec3(c, 0.0, -s) / texture_size_m.x;", "	p.gu = vec3(c, 0.0, s) / texture_size_m.x;")],
     [("render", "pom_matches")]),
    ("triplanar X plane mirrored", "the X plane's u axis points the other way",
     [(CORE, "		right = vec3(0.0, 0.0, -sg);", "		right = vec3(0.0, 0.0, sg);")],
     [("render", "pom_matches")]),
    ("zero-weight planes marched", "triplanar marches all three planes, also those with no weight",
     [(SURFACE, "		if (wa <= 0.0) {\n			continue; // Zero-weight planes are neither marched nor sampled.", "		if (false) {\n			continue; // Zero-weight planes are neither marched nor sampled.")],
     [("render", "triplanar")]),
    ("no distance fade", "the relief keeps its full depth at every distance",
     [(SURFACE, "	float amp = height_m * fade;", "	float amp = height_m + 0.0 * fade;")],
     [("render", "fade")]),
    ("LIGHT_VERTEX not written", "lighting and received shadows use the flat surface, not the relief",
     [(SURFACE, "	LIGHT_VERTEX = VERTEX + offset_view;", "	LIGHT_VERTEX = VERTEX + 0.0 * offset_view;")],
     [("render", "light_vertex")]),
    ("self-shadow ray reversed", "the self-shadow march walks away from the light",
     [(CORE, "	vec2 duv_dz = vec2(dot(gads_ss_gu, l), dot(gads_ss_gv, l)) * (na / max(n_dot_l, GADS_MIN_NDOTV));",
       "	vec2 duv_dz = -vec2(dot(gads_ss_gu, l), dot(gads_ss_gv, l)) * (na / max(n_dot_l, GADS_MIN_NDOTV));")],
     [("render", "self_shadow")]),
    ("light(): Lambert diffuse", "light() uses Lambert while the engine shades with Burley",
     [(COMMON, "		float diffuse_brdf_nl = (1.0 / GADS_PI) * fd_v * fd_l * c_n_dot_l;", "		float diffuse_brdf_nl = (1.0 / GADS_PI) * c_n_dot_l + 0.0 * fd_v * fd_l;")],
     [("render", "light_function")]),
    ("light(): clamped GGX", "D clamped to 1 (the engine's saturateHalf is not a clamp)",
     [(COMMON, "	return k * k * (1.0 / GADS_PI);", "	return clamp(k * k * (1.0 / GADS_PI), 0.0, 1.0);")],
     [("render", "light_function")]),
    ("light(): no energy compensation", "direct specular without the engine's multiple-scattering term",
     [(COMMON, "		vec3 energy_compensation = 1.0 + f0 * (1.0 / max(e, 1e-4) - 1.0);", "		vec3 energy_compensation = vec3(1.0) + 0.0 * e;")],
     [("render", "light_function")]),
    ("depth-write leak", "every POM variant writes DEPTH, not only the opt-in ones",
     [(SURFACE, "#ifdef GADS_DEPTH_WRITE\n	// With the depth pre-pass on,", "#ifdef GADS_POM\n	// With the depth pre-pass on,")],
     [("render", "depth")]),
    ("depth not rounded", "the opt-in depth write without the rounding that keeps both passes equal",
     [(SURFACE, "	DEPTH = round(depth / depth_step) * depth_step;", "	DEPTH = depth + 0.0 * depth_step;")],
     [("render", "depth")]),
    ("no LOD seam stitch", "rings do not geomorph towards the next ring (open T-junctions at ring seams)",
     [(FIELD_SH, "	vec2 lattice_m = lattice - odd * spacing_units * m;", "	vec2 lattice_m = lattice - odd * spacing_units * m * 0.0;")],
     [("field", "cracks,swim")]),
    ("no grid snapping", "the grid follows the camera continuously (vertices slide over the height map)",
     [(FIELD, "	return Vector3(floorf(p.x / snap + 0.5) * snap, 0.0, floorf(p.z / snap + 0.5) * snap)", "	return Vector3(p.x, 0.0, p.z) + 0.0 * snap * Vector3.ONE")],
     [("field", "vertex,swim")]),
    ("vertex fetch at mip 0", "the geometry samples the full-size height map (aliasing, sparkle)",
     [(FIELD_SH, "	float lod = log2(base_spacing) + (level + m);", "	float lod = -20.0 + 0.0 * (log2(base_spacing) + level + m);")],
     [("field", "vertex")]),
    ("relief pushed down", "the field displaces downwards (the ground would hide it)",
     [(FIELD_SH, "	float y = ground + lift + gads_field_fade(xz) * gads_fade(view_distance) * gads_field_relief(xz, lod, w);",
       "	float y = ground + lift - gads_field_fade(xz) * gads_fade(view_distance) * gads_field_relief(xz, lod, w);")],
     [("field", "vertex")]),
    ("pebbles hashed by window slot", "each pebble's random position, size and turn seeded by its slot in the camera window, not its world cell",
     [(PEBBLES, "	uint state = gads_hash(uint(world_cell.x) * 73856093u ^ uint(world_cell.y) * 19349663u",
       "	uint state = gads_hash(uint(cell_xy.x) * 73856093u ^ uint(cell_xy.y) * 19349663u")],
     [("field", "pebbles")]),
    ("bake ignores layers", "every ground surface is captured as 'not displaceable'",
     [(BAKE, "			copy.set_surface_override_material(s, materials[layer_index(surface_material(mi, s), layers) + 1])",
       "			copy.set_surface_override_material(s, materials[0 * layer_index(surface_material(mi, s), layers)])")],
     [("field", "bake")]),
    ("inverted remap flattens", "height_remap (1, 0) clamps its negative span to 1e-5 (every height becomes 0)",
     [(COMMON, "	span = abs(span) < 1e-5 ? 1e-5 : span;", "	span = max(span, 1e-5);")],
     [("render", "inverted_height_remap")]),
    ("field parallax sign", "the field's fragments march the view ray the wrong way",
     [(FIELD_SH, "		vec2 dxz_dz = v.xz * (n.y / nv);", "		vec2 dxz_dz = -v.xz * (n.y / nv);")],
     [("field", "field_pom")]),
    ("field self-shadow reversed", "the field's self-shadow march walks away from the light",
     [(FIELD_SH, "	vec2 dxz_dz = vec2(dot(f_ss_x, l), dot(f_ss_z_axis, l)) * (na / max(n_dot_l, GADS_MIN_NDOTV));",
       "	vec2 dxz_dz = -vec2(dot(f_ss_x, l), dot(f_ss_z_axis, l)) * (na / max(n_dot_l, GADS_MIN_NDOTV));")],
     [("field", "field_pom")]),
    ("ground steps not marked (shader)", "the field treats kerbs as ground (drapes a ramp over them)",
     [(GROUND, "	float limit = ground_decode.z;", "	float limit = 1e9 + 0.0 * ground_decode.z;")],
     [("field", "baked_ground")]),
    ("ground steps not marked (CPU)", "GADSGroundBake.sample() treats kerbs as ground",
     [(BAKE, "			ok = ok and covered[n] and absf(h[n] - h[c]) <= step_limit", "			ok = ok and covered[n]")],
     [("logic", "")]),
    ("ground beyond the bake displaced", "texels outside the bake count as covered (the field continues past the ground's edge)",
     [(GROUND, "		covered[k] = p == pc && d.a > 0.5;", "		covered[k] = d.a > 0.5;")],
     [("field", "baked_ground")]),
    ("field relief lifted", "the field marches its relief from ground + lift, not from the ground (a 2 mm shift against the ground's parallax)",
     [(FIELD_SH, "	float z_hit = wpos.y - f_ground;", "	float z_hit = wpos.y - (f_ground + lift);")],
     [("field", "edge_blends")]),
    ("feature switch adds features", "a feature switch turns on what the preset leaves out",
     [(MANAGER, "	base.near_field_enabled = base.near_field_enabled and near_field", "	base.near_field_enabled = near_field")],
     [("logic", "")]),
    ("local lights never self-shadow", "omni and spot lights ignore gads_pom_steps.w (directional lights only)",
     [(SURFACE, "	if (LIGHT_IS_DIRECTIONAL || gads_pom_steps.w > 0.5) {", "	if (LIGHT_IS_DIRECTIONAL) {")],
     [("render", "local_light")]),
    ("local lights always self-shadow", "omni and spot lights self-shadow whatever the settings say",
     [(SURFACE, "	if (LIGHT_IS_DIRECTIONAL || gads_pom_steps.w > 0.5) {", "	if (LIGHT_IS_DIRECTIONAL || gads_pom_steps.w > -0.5) {")],
     [("render", "local_light")]),
    ("field parameters set every time", "the field sets its parameters even when they did not change (the editor's layer refresh every 30 frames then makes the scatter re-upload its textures)",
     [(FIELD, "	if _material.get_shader_parameter(param) != value:", "	if true:")],
     [("logic", "")]),
    ("scatter stops following the field", "the scatter copies the field's parameters once and never again",
     [(SCATTER, "	if field.get_instance_id() != _copied_field_id or field.get_parameters_version() != _copied_version:",
       "	if field.get_instance_id() != _copied_field_id:")],
     [("logic", "")]),
    ("presets miss CSG shapes", "materials on CSG shapes are not found, so presets do not switch them",
     [(MATERIALS, "	elif node.is_class(\"CSGShape3D\"):", "	elif false:")],
     [("logic", "")]),
    ("custom settings not followed", "edits to a Custom preset's settings resource do not apply",
     [(MANAGER, "			custom_settings.changed.connect(_queue_apply)", "			pass")],
     [("logic", "")]),
    ("demo camera script after ready", "the demo attaches its fly camera script after the camera is ready",
     [(DEMO, "	cam.set_script(FlyCamera)\n	add_child(scene)", "	add_child(scene)\n	cam.set_script(FlyCamera)")],
     [("field", "demo_camera")]),
    ("detail layer outside the slab", "the march starts at the main relief's top, below the detail layer's peaks",
     [(CORE, "	return arg * (1.0 - height_center + 0.5 * gads_detail_ratio());", "	return arg * (1.0 - height_center);")],
     [("render", "detail_layer")]),
    ("layers blend without heights", "layers cross-fade by their mask alone instead of the higher relief winning",
     [(CORE, "	return smoothstep(-width, width, above - below + (2.0 * m - 1.0) * (1.0 + width));", "	return m;")],
     [("render", "layered")]),
    ("layer slope band ignored", "a layer meant for tops covers every face",
     [(CORE, "	return band.y > band.x ? smoothstep(band.x, band.y, up) : 1.0;", "	return 1.0;")],
     [("render", "layered")]),
    ("baked mesh still marches", "a baked mesh runs the parallax march over relief its geometry already has",
     [(SURFACE, "	float amp = gads_baked > 0.5 ? 0.0 : height_m * fade;", "	float amp = height_m * fade;")],
     [("bake", "renders")]),
    ("baked normal map lit twice", "a baked mesh applies the full normal map on top of its geometry's slope",
     [(SURFACE, "	if (gads_baked > 0.5) {\n		nm = gads_detail_normal(nm, p, uv_hit);\n	}\n	NORMAL_MAP = nm;", "	NORMAL_MAP = nm;")],
     [("bake", "renders")]),
    ("bake key ignores the basis", "scaling or rotating a baked mesh does not make its bake stale",
     [(MESH_BAKER, "	parts.append(_rounded(basis_values))", "	pass")],
     [("bake", "staleness")]),
    ("occluders above the surface", "terrain occluders raised instead of lowered: they would hide visible ground",
     [(TERRAIN, "			points.append(verts[z * n + x] - Vector3(0, drop, 0))", "			points.append(verts[z * n + x] + Vector3(0, drop, 0))")],
     [("terrain", "occluders")]),
    ("field lattice on the CPU", "the field's lattice mesh has real positions, which a navigation bake takes for ground",
     [(FIELD, "				positions.append(Vector3.ZERO)", "				positions.append(Vector3(i * step, 0.0, j * step))")],
     [("terrain", "navigation")]),
    ("height hook ignored", "a custom shader's height hook does not reach the march",
     [(CORE, "	h = clamp(gads_custom_height(uv, h), 0.0, 1.0);", "	h = h;")],
     [("render", "custom_shader_hooks")]),
    ("parallax node does not march", "the GADSParallaxUV visual shader node returns the rasterized uv",
     [("addons/gads/visual_shader/gads_vs_parallax.gd", "	vec2 duv_dz = vec2(dot(gu, view), dot(gv, view)) / nv;", "	vec2 duv_dz = vec2(0.0);")],
     [("render", "visual_shader_nodes")]),
    ("cover on every slope", "surface effects cover walls as much as level ground",
     [(COMMON, "		float facing = e.cover.z > e.cover.y ? smoothstep(e.cover.y, e.cover.z, up) : 1.0;", "		float facing = 1.0;")],
     [("render", "surface_effects")]),
    ("field ignores the weather", "the near-camera field draws the ground without the weather's snow",
     [(FIELD_SH, "	e.cover.x = max(e.cover.x, gads_weather.y * response);", "	e.cover.x = e.cover.x;")],
     [("field", "weather")]),
    ("vector map unsigned", "a signed vector displacement map is read as 0..1 around 0.5",
     [(MESH_BAKER, '		out["vector_signed"] = GADSMaterials.get_param(sm, "vector_displacement_signed")', '		out["vector_signed"] = false')],
     [("bake", "vector_displacement")]),
    ("vector map off without height", "a material with a vector map and no height map is not displaced",
     [(MESH_BAKER, "	if not has_height and vector_m <= 0.0:", "	if not has_height:")],
     [("bake", "vector_displacement")]),
    ("sculpt not in the bake key", "painting the sculpt map leaves the bake key as it was, so the old bake is loaded again",
     [(MESH_NODE, '		settings["sculpt"] = _sculpt_stats().get("hash", "")', '		pass')],
     [("bake", "sculpt")]),
    ("sculpt not baked", "the bake runs without the sculpt map",
     [(MESH_NODE, "	_baker.sculpt_image = _sculpt_for_bake()", "	_baker.sculpt_image = null")],
     [("bake", "sculpt")]),
    ("sculpt brush without falloff", "a dab raises its whole disc by the full strength, leaving a step at the rim",
     [(SCULPT, "			f = f * f # smooth to 0 at the rim", "			f = 1.0")],
     [("logic", "")]),
    ("terrain sculpt skips collision", "sculpting a terrain leaves its collision shape as it was",
     [(TERRAIN, "		shape.map_data = map\n	_queue_edit_flush(grown, \"height\")", "		pass\n	_queue_edit_flush(grown, \"height\")")],
     [("terrain", "sculpts")]),
    ("terrain edits lost on rebuild", "the edited heightmap's texture is never updated, so a rebuild reads the old heights",
     [(TERRAIN, "		(heightmap as ImageTexture).update(_height_image())", "		pass")],
     [("terrain", "sculpts")]),
    ("terrain ground data not edited", "the detail field keeps its ground data under a sculpted terrain",
     [(TERRAIN, "	_edit_maps_dirty = {}\n	_update_ground_region(rect)", "	_edit_maps_dirty = {}")],
     [("terrain", "sculpts")]),
    ("skinned clusters without the skeleton", "a skinned bake's clusters stay in the rest pose while the node deforms",
     [(MESH_NODE, "		mi.set_instance_shader_parameter(BAKED_PARAMETER, 1.0)\n		_share_skin(mi)", "		mi.set_instance_shader_parameter(BAKED_PARAMETER, 1.0)")],
     [("bake", "skinned")]),
    ("blend shapes read as offsets", "a blend shape's absolute positions are taken as offsets from the base",
     [(MESH_BAKER, 'tess.call("set_blend_shapes", s, shaped.surface_get_blend_shape_arrays(s), false)', 'tess.call("set_blend_shapes", s, shaped.surface_get_blend_shape_arrays(s), true)')],
     [("bake", "blend_shapes")]),
    ("bake cache ignored", "every bake runs again although a bake of the same inputs is saved",
     [(MESH_NODE, "	if not force and ResourceLoader.exists(paths[0])", "	if false and ResourceLoader.exists(paths[0])")],
     [("bake", "node_bake")]),
    ("bake collision body saved", "the collision body is an ordinary child, saved with the scene",
     [(MESH_NODE, "		add_child(_body, false, Node.INTERNAL_MODE_BACK)", "		add_child(_body)")],
     [("bake", "collision")]),
    ("clusters switch one by one", "each cluster of a clustered bake switches to the parallax fallback by its own distance",
     [(MESH_NODE, "	var hlod := _owns_visibility_range and _fallback != null and not _cluster_nodes.is_empty()", "	var hlod := false")],
     [("bake", "cluster_node")]),
    ("runtime tessellation never refreshes", "a view-dependent mesh keeps its first tessellation however far the camera moves",
     [(MESH_NODE, "		var moved := eye.distance_to(_view_eye) > view_refresh * dist", "		var moved := false")],
     [("bake", "runtime_tessellation")]),
    ("world parallax ignores deformation", "world-planar materials draw the relief as if nothing pressed it down",
     [(SURFACE, "	float deform = gads_deformation(gads_world_pos.xz);", "	float deform = 0.0;")],
     [("render", "deformation")]),
    ("terrain skirts too shallow", "skirts as deep as half the largest LOD error leave gaps between chunks",
     [(TERRAIN, "	var skirt := 2.0 * largest + _spacing * 0.05 + 0.01", "	var skirt := 0.5 * largest")],
     [("terrain", "chunk_lods")]),
    ("terrain ground data off the vertices", "the detail field's ground texels sit half a texel off the terrain's vertices",
     [(TERRAIN, "_origin - Vector2(texel, texel) * 0.5 + Vector2(gp.x, gp.z), texel)", "_origin + Vector2(gp.x, gp.z), texel)")],
     [("terrain", "ground_data")]),
    ("compatibility depth range", "the depth write uses Vulkan's 0..1 clip depth on OpenGL's -1..1",
     [(SURFACE, "	depth = depth * 0.5 + 0.5; // OpenGL clip depth is -1..1; DEPTH (gl_FragDepth) is 0..1", "")],
     [("compat", "")]),
]

SUITES = {
    "logic": (["--headless", "--script", "tests/run_logic_tests.gd"], r"logic tests: \d+ passed, \d+ failed"),
    "render": (["--script", "tests/render_tests.gd"], r"render tests: \d+ passed, \d+ failed"),
    "field": (["--script", "tests/field_tests.gd"], r"field tests: \d+ passed, \d+ failed"),
    "bake": (["--script", "tests/bake_tests.gd"], r"bake tests: \d+ passed, \d+ failed"),
    "terrain": (["--script", "tests/terrain_tests.gd"], r"terrain tests: \d+ passed, \d+ failed"),
    "compat": (["--rendering-method", "gl_compatibility", "--script", "tests/renderer_tests.gd"],
               r"renderer tests \(gl_compatibility\): \d+ passed, \d+ failed"),
}


def godot(args: list[str], timeout: int = 1800) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(RUNNER), "--timeout", str(timeout)] + args,
                          cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")


def reimport() -> None:
    godot(["--headless", "--import"], 900)


def run_tests(targets: list[tuple[str, str]]) -> tuple[bool, list[str]]:
    """True when at least one targeted test failed; also the FAIL lines and measurements."""
    caught = False
    lines = []
    for suite, only in targets:
        args, summary = SUITES[suite]
        proc = godot(args + (["--", "--only=" + only] if only else []))
        out = proc.stdout + proc.stderr
        fails = [line.strip() for line in out.splitlines() if line.strip().startswith("FAIL")]
        measured = [line.rstrip() for line in out.splitlines() if line.startswith("  ") and not line.strip().startswith(("ok", "FAIL", "at:", "GDScript", "["))]
        m = re.search(summary, out)
        lines.append(f"{suite} '{only}': {m.group(0) if m else 'no summary (exit %d)' % proc.returncode}")
        lines += ["|" + line for line in measured[:12]] + fails
        caught = caught or (proc.returncode != 0 and bool(fails))
    return caught, lines


def main() -> int:
    words = sys.argv[1:]
    selected = [m for m in MUTATIONS if not words or any(w in m[0] for w in words)]
    survived = []
    for name, description, edits, targets in selected:
        originals: dict[str, str] = {}
        imports = any(path.endswith(".import") for path, _, _ in edits)
        try:
            for path, old, new in edits:
                file = ROOT / path
                current = file.read_text(encoding="utf-8")
                originals.setdefault(path, current)
                if old not in current:
                    raise LookupError(f"pattern not found in {path}: {old!r}")
                file.write_text(current.replace(old, new, 1), encoding="utf-8", newline="\n")
            if imports:
                reimport()
            caught, lines = run_tests(targets)
            print(f"{'CAUGHT  ' if caught else 'SURVIVED'} {name}: {description}", flush=True)
            for line in lines:
                print(f"         {line}", flush=True)
            if not caught:
                survived.append(name)
        except LookupError as error:
            # The code the mutation targets changed: the mutation must be updated, not skipped.
            print(f"STALE    {name}: {error}", flush=True)
            survived.append(name)
        finally:
            for path, text in originals.items():
                (ROOT / path).write_text(text, encoding="utf-8", newline="\n")
            if imports:
                reimport()
    print(f"\n{len(selected) - len(survived)}/{len(selected)} mutations caught")
    return 1 if survived else 0


if __name__ == "__main__":
    sys.exit(main())
